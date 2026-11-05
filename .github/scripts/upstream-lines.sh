#!/usr/bin/env bash
# Compares the upstream lines the line branches build from with Docker Hub. The lines are the env lists
# NGINX_VERSIONS, PHP_VERSIONS and ALPINE_VERSIONS in .github/workflows/docker.yml of every line branch
# (<major>.0, major >= MIN_LINE_MAJOR); the images are built from nginx:<nginx>-alpine and
# php:<php>-fpm-alpine<alpine>. Run weekly by .github/workflows/upstream-lines.yml.
#
#   upstream-lines.sh plan <plan.json>
#       Read-only. Reads the line branches from the remote-tracking refs ($REMOTE/<branch>), Docker Hub and the
#       PRs of this check, prints a report and writes the plan. Run it locally as a dry run.
#   upstream-lines.sh apply <plan.json> <branch> <checkout-dir> <out-dir>
#       Adds the lines the plan proposes for <branch> to docker.yml and README.md in <checkout-dir> and writes
#       title.txt, commit.txt and body.md of the PR to <out-dir>. Changes local files only.
#   upstream-lines.sh issue <plan.json>
#       Opens, updates or closes the issue that lists the frozen lines. DRY_RUN=1 only prints what it would do.
#
# Rules (FROZEN_AFTER_DAYS, default 30):
# - nginx: the current lines are the <x.y>-alpine tags with the digest of stable-alpine and mainline-alpine.
#   A new stable line is proposed on every line branch (projects on older lines need an nginx that upstream
#   still updates), a new mainline line only on the newest line branch.
# - PHP/Alpine: php:<php>-fpm-alpine<alpine> is maintained if upstream pushed it within FROZEN_AFTER_DAYS (the
#   cli tag is pushed by the same upstream build). A newer PHP or Alpine minor is proposed on the newest line
#   branch only, and only if every combination it adds to the build matrix is maintained; otherwise it is
#   reported as waiting.
# - frozen: a listed nginx line that is neither the current stable nor mainline, or a listed PHP/Alpine
#   combination, whose tag upstream last pushed more than FROZEN_AFTER_DAYS ago while it pushes newer lines.
#   A listed tag that does not exist is reported too. Combinations excluded by INCOMPATIBLE_MATRIX or built
#   from our own php-backport images (BACKPORT_COMBOS in docker-build.yml) are skipped.
# - A line proposed in a PR of this check that was closed without merging is not proposed again on that branch.
#
# Any failed Docker Hub or GitHub request aborts the run, so that an outage never closes PRs or the issue.
set -euo pipefail
# a failed Docker Hub/GitHub request inside $(...) must abort the run as well
shopt -s inherit_errexit

FROZEN_AFTER_DAYS=${FROZEN_AFTER_DAYS:-30}
MIN_LINE_MAJOR=${MIN_LINE_MAJOR:-7}
REMOTE=${REMOTE:-origin}
PR_BRANCH_PREFIX=${PR_BRANCH_PREFIX:-upstream-lines/}
HUB=${HUB:-https://hub.docker.com/v2/repositories/library}
ISSUE_MARKER='<!-- upstream-lines:frozen -->'

# shared jq definitions
# shellcheck disable=SC2016 # jq, not shell
JQ_DEFS='
def v: split(".") | map(tonumber);
def maxv: if length == 0 then null else max_by(v) end;
def gt($a; $b): $b == null or ($a | v) > ($b | v);
def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def age: if . == null then null else ((now - epoch) / 86400 | floor) end;
def day: if . == null then "never" else .[0:10] end;
def includes($x): any(.[]; . == $x);
def words: (. // "") | [splits("\\s+")] | map(select(. != ""));
def phptag: "php:\(.php)-fpm-alpine\(.alpine)";
# one row per image; $new: "<branch> <tag>" keys to mark as new
def frozen_table($new):
  "| Image | Last pushed | Listed on | Upstream now |",
  "|---|---|---|---|",
  (.frozen | group_by(.tag)[]
    | "| `\(.[0].tag)` | \(if .[0].reason == "missing" then "does not exist" else "\(.[0].pushed | day) (\(.[0].age) days)" end) | \(
      map(.branch + (if ("\(.branch) \(.tag)" as $k | $new | includes($k)) then " (new)" else "" end)) | join(", ")) | \(.[0].now) |");
'

die() {
  echo "::error::$*" >&2
  exit 1
}

need() {
  for cmd in "$@"; do
    command -v "$cmd" > /dev/null || die "$cmd is required"
  done
}

repo() {
  if [ -n "${GH_REPO:-}" ]; then
    echo "$GH_REPO"
  elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    echo "$GITHUB_REPOSITORY"
  else
    gh repo view --json nameWithOwner --jq .nameWithOwner
  fi
}

run_url() {
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  fi
}

# --- Docker Hub -------------------------------------------------------------------------------------------

# Prints the tag's JSON, {} if it does not exist. Cached per run.
hub_tag() {
  local repo=$1 tag=$2 file code
  file="$CACHE/tag-$repo-$tag.json"
  if [ ! -f "$file" ]; then
    code=$(curl -sS --retry 4 --retry-delay 5 -o "$file.tmp" -w '%{http_code}' "$HUB/$repo/tags/$tag") \
      || die "Docker Hub: $repo:$tag: request failed"
    case $code in
      200) mv "$file.tmp" "$file" ;;
      404) echo '{}' > "$file" && rm -f "$file.tmp" ;;
      *) die "Docker Hub: $repo:$tag: HTTP $code" ;;
    esac
  fi
  cat "$file"
}

# Prints [{name, digest, pushed}] of the tags whose name contains <filter>, newest first, until the tags are
# older than <since> (epoch seconds; at most 10 pages of 100).
hub_list() {
  local repo=$1 filter=$2 since=$3 url page=1 file
  url="$HUB/$repo/tags?page_size=100&ordering=last_updated&name=$filter"
  while [ -n "$url" ] && [ "$page" -le 10 ]; do
    file="$CACHE/list-$repo-$filter-$page.json"
    curl -fsS --retry 4 --retry-delay 5 --retry-all-errors -o "$file" "$url" \
      || die "Docker Hub: listing $repo tags failed"
    url=$(jq -r --argjson since "$since" "$JQ_DEFS"'
      if (.results | length) > 0 and ((.results[-1].last_updated // "1970-01-01T00:00:00Z") | epoch) >= $since
      then .next // "" else "" end' "$file")
    page=$((page + 1))
  done
  jq -s '[.[].results[] | {name, digest, pushed: .tag_last_pushed}]' "$CACHE/list-$repo-$filter-"*.json
}

# The current nginx stable and mainline lines: the <x.y>-alpine tags with the digest of stable-alpine and
# mainline-alpine.
nginx_upstream() {
  local stable mainline since list
  stable=$(hub_tag nginx stable-alpine)
  mainline=$(hub_tag nginx mainline-alpine)
  since=$(jq -n --argjson s "$stable" --argjson m "$mainline" "$JQ_DEFS"'
    [$s.tag_last_pushed, $m.tag_last_pushed] | map(select(. != null) | epoch) | (min // now) - 2 * 86400 | floor')
  list=$(hub_list nginx -alpine "$since")
  jq -n --argjson s "$stable" --argjson m "$mainline" --argjson list "$list" '
    def line($d): if $d == null then null else
      [$list[] | select(.digest == $d and (.name | test("^[0-9]+\\.[0-9]+-alpine$"))) | .name | rtrimstr("-alpine")]
      | first end;
    {stable: line($s.digest), stable_pushed: $s.tag_last_pushed,
     mainline: line($m.digest), mainline_pushed: $m.tag_last_pushed}'
}

# [{php, alpine, pushed}] of the php:<php>-fpm-alpine<alpine> tags pushed within FROZEN_AFTER_DAYS.
php_maintained() {
  local since
  since=$(jq -n --argjson d "$FROZEN_AFTER_DAYS" 'now - $d * 86400 | floor')
  hub_list php fpm-alpine "$since" | jq --argjson since "$since" "$JQ_DEFS"'
    [.[] | select(.name | test("^[0-9]+\\.[0-9]+-fpm-alpine[0-9]+\\.[0-9]+$"))
      | select(.pushed != null and (.pushed | epoch) >= $since)
      | (.name | capture("^(?<php>[0-9.]+)-fpm-alpine(?<alpine>[0-9.]+)$")) + {pushed}]
    | unique_by([.php, .alpine])'
}

# --- line branches ----------------------------------------------------------------------------------------

line_branches() {
  git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE/" \
    | awk -F. -v min="$MIN_LINE_MAJOR" '/^[0-9]+\.0$/ && $1 >= min' | sort -t. -k1,1nr
}

# The lines of a branch, the PHP/Alpine combinations it builds and where they come from.
branch_config() {
  local branch=$1 env backport
  env=$(git show "$REMOTE/$branch:.github/workflows/docker.yml" | yq -o=json '.env // {}') \
    || die "$branch: cannot read .github/workflows/docker.yml"
  backport=$(git show "$REMOTE/$branch:.github/workflows/docker-build.yml" 2> /dev/null \
    | sed -n 's/.*BACKPORT_COMBOS="\([^"]*\)".*/\1/p' | head -n 1)
  jq -n --arg branch "$branch" --argjson env "$env" --arg backport "$backport" "$JQ_DEFS"'
    # INCOMPATIBLE_MATRIX is JSON in a YAML string; 8.0 has a trailing comma
    (($env.INCOMPATIBLE_MATRIX // "[]") | gsub(",\\s*(?<c>[\\]}])"; .c) | fromjson) as $incompatible
    | ($backport | words | map(split("/") | {php: .[0], alpine: .[1]})) as $backport
    | def excluded($combo): any($incompatible[];
        (keys - ($combo | keys)) == [] and (to_entries | all(.value == $combo[.key])));
    {branch: $branch,
     nginx: ($env.NGINX_VERSIONS | words),
     php: ($env.PHP_VERSIONS | words),
     alpine: ($env.ALPINE_VERSIONS | words),
     incompatible: $incompatible}
    | .nginx |= map(select(excluded({nginx_version: .}) | not))
    | .combos = [.php[] as $p | .alpine[] as $a | {php: $p, alpine: $a}
        | select(excluded({php_version: .php, alpine: .alpine}) | not)]
    | .backported = [.combos[] | select(. as $c | $backport | includes($c))]
    | .upstream_combos = .combos - .backported
    | if (.nginx + .php + .alpine) == [] then error("\($branch): no lines in docker.yml") else . end'
}

# {open, rejected} of the PRs of this check for a branch. rejected: the lines of PRs closed without merging.
branch_prs() {
  local branch=$1
  gh pr list --repo "$(repo)" --head "$PR_BRANCH_PREFIX$branch" --state all --limit 100 --json number,state,body \
    | jq '
      def marker: (capture("<!-- upstream-lines: (?<m>[^>]*) -->") // {m: ""}).m
        | [splits(" +") | select(contains("=")) | split("=") | {key: .[0], value: (.[1] | split(",") | map(select(. != "")))}]
        | from_entries;
      {open: (map(select(.state == "OPEN")) | first | .number // null),
       rejected: (reduce (.[] | select(.state == "CLOSED") | .body // "" | marker) as $m
         ({nginx: [], php: [], alpine: []};
          .nginx += ($m.nginx // []) | .php += ($m.php // []) | .alpine += ($m.alpine // []))
         | map_values(unique))}'
}

# --- plan -------------------------------------------------------------------------------------------------

cmd_plan() {
  local out=$1 branches configs nginx maint tags prs pr plan repo_name tag json
  need git jq yq curl gh

  branches=$(line_branches)
  [ -n "$branches" ] || die "no line branches on $REMOTE (fetch with: git fetch $REMOTE)"
  configs=$(for b in $branches; do branch_config "$b"; done | jq -s .)

  nginx=$(nginx_upstream)
  jq -e '.stable != null' > /dev/null <<< "$nginx" || die "Docker Hub: no nginx <x.y>-alpine tag with the digest of stable-alpine"
  maint=$(php_maintained)
  jq -e 'length > 0' > /dev/null <<< "$maint" \
    || die "Docker Hub: no php fpm-alpine tag pushed in the last $FROZEN_AFTER_DAYS days, refusing to call everything frozen"

  # every tag a branch builds from
  tags=$(jq -r '[.[] | (.nginx[] | "nginx \(.)-alpine"), (.upstream_combos[] | "php \(.php)-fpm-alpine\(.alpine)")]
    | unique[]' <<< "$configs" \
    | while read -r repo_name tag; do
        json=$(hub_tag "$repo_name" "$tag")
        jq -c --arg key "$repo_name:$tag" '{key: $key, value: {exists: (. != {}), pushed: .tag_last_pushed}}' <<< "$json"
      done | jq -s from_entries)

  prs=$(for b in $branches; do
    pr=$(branch_prs "$b")
    jq -c --arg b "$b" '{key: $b, value: .}' <<< "$pr"
  done | jq -s from_entries)

  plan=$(jq -n --argjson configs "$configs" --argjson nginx "$nginx" --argjson maint "$maint" \
    --argjson tags "$tags" --argjson prs "$prs" --argjson days "$FROZEN_AFTER_DAYS" "$JQ_DEFS"'
    ($configs | map(.branch) | maxv) as $newest
    | ([$nginx.stable, $nginx.mainline] | map(select(. != null)) | unique) as $nginx_current
    | ($nginx_current | maxv) as $nginx_newest
    | ($maint | map(.php) | unique) as $maint_php
    | ($maint | map(.alpine) | unique) as $maint_alpine
    | def maintained($c): any($maint[]; .php == $c.php and .alpine == $c.alpine);
      def pushed($c): [$maint[] | select(.php == $c.php and .alpine == $c.alpine) | .pushed] | first;
      def tag($t): $tags[$t] // {exists: false, pushed: null};
      def excluded($cfg; $combo): any($cfg.incompatible[];
        (keys - ($combo | keys)) == [] and (to_entries | all(.value == $combo[.key])));
      def nginx_role($l): if $l == $nginx.stable then "stable" elif $l == $nginx.mainline then "mainline" else null end;
      def nginx_pushed($l): if $l == $nginx.stable then $nginx.stable_pushed else $nginx.mainline_pushed end;
      def new_combos($cfg; $php; $alpine):
        [$php[] as $p | $alpine[] as $a | {php: $p, alpine: $a}
          | select(excluded($cfg; {php_version: .php, alpine: .alpine}) | not)];

    [ $configs[] as $c
      | ($prs[$c.branch] // {open: null, rejected: {nginx: [], php: [], alpine: []}}) as $pr
      | ($c.branch == $newest) as $is_newest
      | (if $is_newest then $nginx_current else [$nginx.stable] end
         | map(select(. != null and (. as $l | ($c.nginx | includes($l)) or ($pr.rejected.nginx | includes($l)) | not))))
        as $nginx_add
      # PHP minors newer than the newest listed one; every combination with the listed Alpine lines must exist
      | [if $is_newest then $maint_php[] else empty end
         | select(gt(.; $c.php | maxv) and (. as $p | $pr.rejected.php | includes($p) | not))
         | {kind: "php", line: ., missing: [new_combos($c; [.]; $c.alpine)[] | select(maintained(.) | not) | phptag]}]
        as $php_checked
      | ($php_checked | map(select(.missing == []) | .line)) as $php_add
      # Alpine minors newer than the newest listed one; every combination with the PHP lines must exist
      | [if $is_newest then $maint_alpine[] else empty end
         | select(gt(.; $c.alpine | maxv) and (. as $a | $pr.rejected.alpine | includes($a) | not))
         | {kind: "alpine", line: .,
            missing: [new_combos($c; $c.php + $php_add; [.])[] | select(maintained(.) | not) | phptag]}]
        as $alpine_checked
      | ($alpine_checked | map(select(.missing == []) | .line)) as $alpine_add
      | {branch: $c.branch, newest: $is_newest,
         nginx: $c.nginx, php: $c.php, alpine: $c.alpine,
         backported: ($c.backported | map("\(.php)/\(.alpine)")),
         open_pr: $pr.open, rejected: $pr.rejected,
         add: {nginx: $nginx_add, php: $php_add, alpine: $alpine_add},
         evidence: (
           [$nginx_add[] | {kind: "nginx", line: ., role: nginx_role(.),
              tags: [{name: "nginx:\(.)-alpine", pushed: nginx_pushed(.)}]}]
           + [$php_add[] as $p | {kind: "php", line: $p,
              tags: [new_combos($c; [$p]; $c.alpine + $alpine_add)[] | {name: phptag, pushed: pushed(.)}]}]
           + [$alpine_add[] as $a | {kind: "alpine", line: $a,
              tags: [new_combos($c; $c.php + $php_add; [$a])[] | {name: phptag, pushed: pushed(.)}]}]),
         waiting: ($php_checked + $alpine_checked | map(select(.missing != []))),
         frozen: (
           [$c.nginx[] as $l | ("nginx:\($l)-alpine") as $name | tag($name) as $t
             | if ($t.exists | not) then {kind: "nginx", line: $l, tag: $name, pushed: null, reason: "missing"}
               elif ($nginx_current | includes($l) | not) and ($t.pushed | age) > $days and gt($nginx_newest; $l)
               then {kind: "nginx", line: $l, tag: $name, pushed: $t.pushed, reason: "frozen"}
               else empty end
             | . + {now: ([if $nginx.stable then "stable \($nginx.stable)" else empty end,
                           if $nginx.mainline then "mainline \($nginx.mainline)" else empty end] | join(", "))}]
           + [$c.upstream_combos[] as $x | ($x | phptag) as $name | tag($name) as $t
             | ([$maint[] | select(.php == $x.php) | .alpine] | maxv) as $newest_alpine
             | if ($t.exists | not) then {kind: "php", line: "\($x.php)/\($x.alpine)", tag: $name, pushed: null, reason: "missing"}
               elif ($t.pushed | age) > $days
                 and any($maint[]; gt(.php; $x.php) or (.php == $x.php and gt(.alpine; $x.alpine)))
               then {kind: "php", line: "\($x.php)/\($x.alpine)", tag: $name, pushed: $t.pushed, reason: "frozen"}
               else empty end
             | . + {now: (if $newest_alpine then "PHP \($x.php) on Alpine \($newest_alpine)"
                          else "PHP \($x.php) not built any more, newest: \($maint_php | maxv)" end)}]
           | map(. + {age: (.pushed | age)}))}
    ] as $branches
    | {frozen_after_days: $days, newest_branch: $newest,
       upstream: {nginx: $nginx, php: $maint},
       branches: $branches,
       propose: [$branches[] | select((.add | add | length) > 0 or .open_pr != null) | .branch],
       frozen: [$branches[] | .branch as $b | .frozen[] | {branch: $b} + .]}')

  printf '%s\n' "$plan" > "$out"
  report "$out"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    report "$out" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "plan=$(jq -c . "$out")"
      echo "propose=$(jq -c .propose "$out")"
    } >> "$GITHUB_OUTPUT"
  fi
}

report() {
  jq -r "$JQ_DEFS"'
    def list: if length == 0 then "–" else join(", ") end;
    "## Upstream lines",
    "",
    "nginx: stable \(.upstream.nginx.stable // "?") (pushed \(.upstream.nginx.stable_pushed | day)), mainline \(.upstream.nginx.mainline // "?") (pushed \(.upstream.nginx.mainline_pushed | day))",
    "",
    "PHP/Alpine pushed in the last \(.frozen_after_days) days: \(.upstream.php | map("\(.php)/\(.alpine)") | join(" "))",
    "",
    "| Branch | nginx | PHP | Alpine | Proposed | Frozen / missing |",
    "|---|---|---|---|---|---|",
    (.branches[] | "| \(.branch) | \(.nginx | join(" ")) | \(.php | join(" ")) | \(.alpine | join(" ")) | \(
      [(.add.nginx[] | "nginx \(.)"), (.add.php[] | "PHP \(.)"), (.add.alpine[] | "Alpine \(.)")] | list)\(
      if .open_pr then " (PR #\(.open_pr))" else "" end) | \(.frozen | map(.tag) | list) |"),
    "",
    if .frozen == [] then "No frozen lines." else
      "### Frozen or missing upstream",
      "",
      frozen_table([])
    end,
    (([.branches[] | .branch as $b | .waiting[] | "- \($b): \(.kind) \(.line), missing upstream: \(.missing | join(", "))"]) as $w
      | if $w == [] then empty else "", "### Waiting (not every new combination exists upstream yet)", "", $w[] end),
    (([.branches[] | select(.backported != []) | "- \(.branch): \(.backported | join(" "))"]) as $b
      | if $b == [] then empty else "", "### Skipped, built from our php-backport images", "", $b[] end),
    (([.branches[] | .branch as $b | .rejected | to_entries[] | select(.value != []) | "- \($b): \(.key) \(.value | join(", "))"]) as $r
      | if $r == [] then empty else "", "### Not proposed again (PR closed without merging)", "", $r[] end)
  ' "$1"
}

# --- apply ------------------------------------------------------------------------------------------------

# Adds <values> to the list in the line matched by <awk-regex>; the list is what follows <separator>.
add_to_line() {
  local file=$1 regex=$2 quote=$3 sep=$4 content
  shift 4
  awk -v re="$regex" -v q="$quote" -v sep="$sep" -v add="$*" '
    function vcmp(a, b,   x, y, i, n) {
      n = split(a, x, "."); split(b, y, ".")
      for (i = 1; i <= n; i++) if (x[i] + 0 != y[i] + 0) return x[i] + 0 < y[i] + 0 ? -1 : 1
      return 0
    }
    $0 ~ re && !done {
      if (q != "") { start = index($0, q); stop = start + index(substr($0, start + 1), q) }
      else { start = index($0, ": ") + 1; stop = length($0) + 1 }
      head = substr($0, 1, start); tail = substr($0, stop)
      n = split(substr($0, start + 1, stop - start - 1), cur, sep == " " ? " " : ", ")
      m = 0
      for (i = 1; i <= n; i++) if (cur[i] != "" && !(cur[i] in seen)) { seen[cur[i]] = 1; vals[++m] = cur[i] }
      k = split(add, extra, " ")
      for (i = 1; i <= k; i++) if (!(extra[i] in seen)) { seen[extra[i]] = 1; vals[++m] = extra[i] }
      for (i = 2; i <= m; i++) for (j = i; j > 1 && vcmp(vals[j - 1], vals[j]) > 0; j--) { t = vals[j]; vals[j] = vals[j - 1]; vals[j - 1] = t }
      out = vals[1]; for (i = 2; i <= m; i++) out = out sep vals[i]
      print head out tail; done = 1; next
    }
    { print }
    END { if (!done) exit 3 }' "$file" > "$file.tmp" || return
  # awk ends every line with a newline; keep a file without a final newline as it is
  if [ -n "$(tail -c 1 "$file")" ]; then
    content=$(cat "$file.tmp")
    printf '%s' "$content" > "$file.tmp"
  fi
  mv "$file.tmp" "$file"
}

cmd_apply() {
  local plan=$1 branch=$2 dir=$3 out=$4 entry env var label values readme_note=""
  need jq yq awk
  entry=$(jq -c --arg b "$branch" '.branches[] | select(.branch == $b)' "$plan")
  [ -n "$entry" ] || die "$branch is not in the plan"
  mkdir -p "$out"

  for kind in nginx php alpine; do
    values=$(jq -r --arg k "$kind" '.add[$k] | join(" ")' <<< "$entry")
    [ -n "$values" ] || continue
    case $kind in
      nginx) var=NGINX_VERSIONS label=Nginx ;;
      php) var=PHP_VERSIONS label=PHP ;;
      alpine) var=ALPINE_VERSIONS label=Alpine ;;
    esac
    # shellcheck disable=SC2086 # values is a space separated list
    add_to_line "$dir/.github/workflows/docker.yml" "^[[:space:]]*$var: '" "'" " " $values \
      || die "$branch: no $var line in docker.yml"
    # shellcheck disable=SC2086
    if ! add_to_line "$dir/README.md" "^[[:space:]]*- [*][*][*]${label}[*][*][*]: " "" ", " $values; then
      rm -f "$dir/README.md.tmp"
      readme_note="$readme_note $label"
    fi
  done

  # the lists docker.yml builds now, for the PR text; also checks that the edit kept the YAML valid
  env=$(yq -o=json '.env' "$dir/.github/workflows/docker.yml") || die "$branch: docker.yml is no valid YAML after the edit"
  entry=$(jq -c --argjson env "$env" --arg note "$readme_note" \
    '. + {result: {nginx: $env.NGINX_VERSIONS, php: $env.PHP_VERSIONS, alpine: $env.ALPINE_VERSIONS}, readme_missing: $note}' \
    <<< "$entry")

  jq -r '
    [(.add.nginx[] | "nginx \(.)"), (.add.php[] | "PHP \(.)"), (.add.alpine[] | "Alpine \(.)")] as $all
    | if $all == [] then "\(.branch): no new upstream lines" else "\(.branch): build \($all | join(", "))" end
  ' <<< "$entry" > "$out/title.txt"

  jq -r --arg run "$(run_url)" "$JQ_DEFS"'
    (.evidence | map("\(.kind | if . == "php" then "PHP" elif . == "alpine" then "Alpine" else . end) \(.line)\(
        if .role then " (current \(.role))" else "" end)") | join(", ")) as $what
    | "Upstream (Docker Hub) has lines that \(.branch) does not build yet: \($what).",
      "",
      "Proposed by the weekly upstream line check (.github/workflows/upstream-lines.yml\(if $run != "" then ", \($run)" else "" end))."
  ' <<< "$entry" > "$out/commit.body"
  { cat "$out/title.txt"; echo; cat "$out/commit.body"; } > "$out/commit.txt"
  rm -f "$out/commit.body"

  jq -r --arg run "$(run_url)" "$JQ_DEFS"'
    . as $entry
    | def why:
      if .kind == "nginx" and .role == "stable" then
        "current nginx stable line" + (if $entry.newest then "" else "; projects on \($entry.branch) need an nginx that upstream still updates" end)
      elif .kind == "nginx" then "current nginx mainline line"
      elif .kind == "php" then "new PHP minor, built upstream with every Alpine line of \($entry.branch)"
      else "new Alpine minor, built upstream for every PHP line of \($entry.branch)" end;
    "New upstream lines for `\(.branch)`, found by the weekly upstream line check\(if $run != "" then " ([run](\($run)))" else "" end).",
      "",
      "| Line | Why | Docker Hub |",
      "|---|---|---|",
      (.evidence[] | "| \(.kind | if . == "php" then "PHP" elif . == "alpine" then "Alpine" else . end) \(.line) | \(why) | \(
        .tags | map("`\(.name)` (pushed \(.pushed | day))") | join("<br>")) |"),
      "",
      "`.github/workflows/docker.yml` now builds:",
      "",
      "- `NGINX_VERSIONS`: `\(.result.nginx)`",
      "- `PHP_VERSIONS`: `\(.result.php)`",
      "- `ALPINE_VERSIONS`: `\(.result.alpine)`",
      "",
      (if .readme_missing != "" then "README.md has no version list for:\(.readme_missing); it is unchanged there." else "The version list in README.md is updated as well." end),
      "",
      "`docker.yml` does not run on pull requests, so this PR builds no image. The new images are built by the push to `\(.branch)` after the merge; check that run before the next release.",
      "",
      "Close this PR without merging to keep these lines off `\(.branch)`: the check does not propose a line again on a branch once a PR proposing it was closed unmerged. Lines that upstream no longer updates are tracked in a separate issue.",
      "",
      "<!-- upstream-lines: branch=\(.branch) nginx=\(.add.nginx | join(",")) php=\(.add.php | join(",")) alpine=\(.add.alpine | join(",")) -->"
  ' <<< "$entry" > "$out/body.md"

  cat "$out/title.txt"
}

# --- issue ------------------------------------------------------------------------------------------------

cmd_issue() {
  local plan=$1 repo_name issues action number body_file="$CACHE/issue.md"
  need jq gh
  repo_name=$(repo)

  issues=$(gh api "repos/$repo_name/issues?state=all&sort=created&direction=desc&per_page=100" \
    --jq "[.[] | select(.pull_request == null and ((.body // \"\") | contains(\"$ISSUE_MARKER\")))
      | {number, state, body}]") || die "GitHub: cannot list issues"

  # what to do: compare the frozen lines with the ones the newest issue of this check lists
  action=$(jq -n --slurpfile plan "$plan" --argjson issues "$issues" '
    def items: (capture("<!-- upstream-lines:items\n(?<i>[^>]*)-->") // {i: ""}).i | split("\n") | map(select(. != ""));
    ($plan[0].frozen | map("\(.branch) \(.tag)") | unique) as $now
    | ($issues | first) as $last
    | ($last.body // "" | items) as $before
    | if $last != null and $last.state == "open" then
        if $now == $before then {do: "none", number: $last.number, why: "issue is up to date"}
        elif $now == [] then {do: "close", number: $last.number}
        else {do: "update", number: $last.number, new: ($now - $before)} end
      elif $now == [] then {do: "none", why: "no frozen lines"}
      elif ($now - $before) == [] then
        {do: "none", number: $last.number, why: "all frozen lines were already listed in the closed issue"}
      else {do: "create", new: (if $last == null then [] else $now - $before end)} end')

  issue_body "$plan" "$(jq -r '.new // [] | join("\n")' <<< "$action")" > "$body_file"
  number=$(jq -r '.number // empty' <<< "$action")

  case $(jq -r .do <<< "$action") in
    none)
      echo "Issue: nothing to do ($(jq -r '.why' <<< "$action")${number:+, #$number})"
      ;;
    create)
      echo "Issue: create \"$ISSUE_TITLE\""
      if [ "${DRY_RUN:-0}" = 1 ]; then cat "$body_file"; else
        gh issue create --repo "$repo_name" --title "$ISSUE_TITLE" --body-file "$body_file"
      fi
      ;;
    update)
      echo "Issue: update #$number, newly frozen: $(jq -r '.new | join("; ")' <<< "$action")"
      if [ "${DRY_RUN:-0}" = 1 ]; then cat "$body_file"; else
        gh issue edit "$number" --repo "$repo_name" --body-file "$body_file"
        if jq -e '.new != []' > /dev/null <<< "$action"; then
          gh issue comment "$number" --repo "$repo_name" \
            --body "Newly frozen or missing upstream: $(jq -r '.new | map("`\(.)`") | join(", ")' <<< "$action")"
        fi
      fi
      ;;
    close)
      echo "Issue: close #$number, no frozen lines left"
      if [ "${DRY_RUN:-0}" = 1 ]; then :; else
        gh issue close "$number" --repo "$repo_name" \
          --comment "No listed line is frozen or missing upstream any more${GITHUB_RUN_ID:+ ($(run_url))}."
      fi
      ;;
  esac
}

ISSUE_TITLE='Frozen upstream lines: base images that upstream no longer updates'

issue_body() {
  local plan=$1 new=$2
  jq -r --arg marker "$ISSUE_MARKER" --arg run "$(run_url)" --arg new "$new" "$JQ_DEFS"'
    ($new | split("\n") | map(select(. != ""))) as $new
    | $marker,
      "## Problem",
      "",
      "The line branches still build from these upstream images, but upstream no longer updates them: the tag on Docker Hub was last pushed more than \(.frozen_after_days) days ago while upstream pushes newer lines, or it does not exist. nginx and PHP releases and the fixes of their Alpine base no longer reach our images (the nginx images only get Alpine fixes through `apk upgrade`, as long as that Alpine release is supported).",
      "",
      frozen_table($new),
      "",
      "## Wanted",
      "",
      "Per line: remove it from `.github/workflows/docker.yml` (and the README) of the branch, replace it with a line upstream still updates, or keep it on purpose.",
      "",
      "The weekly upstream line check (`.github/workflows/upstream-lines.yml`) updates this issue when the list changes and closes it when no line is left. If you close it with lines left, they count as accepted: a new issue is only opened when another line freezes.",
      (if $run != "" then "", "Updated by \($run)" else empty end),
      "",
      "<!-- upstream-lines:items",
      (.frozen | map("\(.branch) \(.tag)") | unique[]),
      "-->"
  ' "$plan"
}

# --- main -------------------------------------------------------------------------------------------------

CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"' EXIT

case ${1:-} in
  plan) [ $# -eq 2 ] || die "usage: $0 plan <plan.json>"; cmd_plan "$2" ;;
  apply) [ $# -eq 5 ] || die "usage: $0 apply <plan.json> <branch> <checkout-dir> <out-dir>"; cmd_apply "$2" "$3" "$4" "$5" ;;
  issue) [ $# -eq 2 ] || die "usage: $0 issue <plan.json>"; cmd_issue "$2" ;;
  *) die "usage: $0 plan|apply|issue ..." ;;
esac
