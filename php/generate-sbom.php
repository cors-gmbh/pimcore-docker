#!/usr/bin/env php
<?php

/*
 * Writes a CycloneDX 1.5 SBOM of the software this image installs outside the apk package
 * database: PHP itself (built from source by the official php image), the PEAR packages that
 * come with it, every shared extension that is not part of the PHP source (PECL, git builds,
 * the blackfire probe) and composer including the libraries bundled in its phar.
 *
 * Trivy only detects packages from the apk database and from lock files, so all of this is
 * invisible to it. It does read SBOM files inside an image, though, and matches pkg:bitnami
 * components against the Bitnami vulnerability database. Component names therefore follow
 * Bitnami's conventions (php, pecl<extension>, composer). The PEAR and composer libraries are
 * pkg:composer, which Trivy matches against the GitHub advisories for Packagist.
 *
 * Everything is read from what is actually installed, so run it again in every image that adds
 * or removes PHP extensions:
 *
 *   RUN generate-sbom [output file, default /usr/local/share/sbom/php.cdx.json]
 */

const DEFAULT_OUTPUT = '/usr/local/share/sbom/php.cdx.json';
const PHP_SOURCE = '/usr/src/php.tar.xz';
const PECL_CHANNEL = 'pecl.php.net';
const PEAR_CHANNEL = 'pear.php.net';

// Shared extensions that are not distributed through PECL, with their Bitnami-style name.
const NON_PECL_EXTENSIONS = ['blackfire' => 'blackfire-php'];

function warn(string $message): void
{
    fwrite(STDERR, "generate-sbom: WARNING: $message\n");
}

function isVersion($version): bool
{
    return is_string($version) && preg_match('/^v?\d+(\.\d+)*([.\-+~][0-9A-Za-z.\-+~]*)?$/', $version) === 1;
}

function purl(string $type, string $name, ?string $version): string
{
    $name = implode('/', array_map('rawurlencode', explode('/', $name)));

    return "pkg:$type/$name" . ($version === null ? '' : '@' . rawurlencode($version));
}

/**
 * Maps the free-text licenses of PEAR/PECL package.xml and composer.json files to SPDX
 * identifiers where that is unambiguous, otherwise keeps the text as license name.
 */
function license(?string $name, ?string $uri = null): ?array
{
    $name = trim((string) $name);
    if ($name === '') {
        return null;
    }
    $aliases = [
        '~^php( license)?( v?3\.01)?$~i' => 'PHP-3.01',
        '~^php( license)? v?3\.0$~i' => 'PHP-3.0',
        '~^(new |modified |3-clause )?bsd( license)?$~i' => 'BSD-3-Clause',
        '~^mit( license)?$~i' => 'MIT',
        '~^apache( license)?,? (version )?2\.0$~i' => 'Apache-2.0',
        '~^((l|a)?gpl)-(\d\.\d)\+$~i' => '$1-$3-or-later',
    ];
    foreach ($aliases as $pattern => $id) {
        if (preg_match($pattern, $name)) {
            $name = preg_replace($pattern, $id, $name);
            // "PHP License" without a version: the licence URI tells 3.0 from 3.01
            if ($name === 'PHP-3.01' && $uri !== null && preg_match('~3_0\.txt$~', $uri)) {
                $name = 'PHP-3.0';
            }
            break;
        }
    }
    // Only identifiers known to be on the SPDX list go into "id", the CycloneDX schema
    // rejects anything else there.
    $spdx = [
        'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'ISC', 'MIT', 'MPL-2.0', 'PHP-3.0', 'PHP-3.01',
        'Xdebug-1.03', 'Zlib', 'GPL-2.0-only', 'GPL-2.0-or-later', 'GPL-3.0-only', 'GPL-3.0-or-later',
        'LGPL-2.1-only', 'LGPL-2.1-or-later', 'LGPL-3.0-only', 'LGPL-3.0-or-later', 'AGPL-3.0-only',
    ];
    foreach ($spdx as $id) {
        if (strcasecmp($id, $name) === 0) {
            return ['license' => ['id' => $id]];
        }
    }

    return ['license' => array_filter(['name' => $name, 'url' => $uri])];
}

function component(string $type, string $name, ?string $version, string $purl, array $extra = []): array
{
    return array_filter(
        ['bom-ref' => $purl, 'type' => $type, 'name' => $name, 'version' => $version, 'purl' => $purl] + $extra,
        static fn ($value) => $value !== null && $value !== []
    );
}

/** Extensions in the PHP source tarball the image was built from, null if it is gone. */
function bundledExtensions(): ?array
{
    if (!is_file(PHP_SOURCE)) {
        return null;
    }
    exec('tar -tJf ' . escapeshellarg(PHP_SOURCE) . ' 2>/dev/null', $files, $status);
    if ($status !== 0) {
        return null;
    }
    $extensions = [];
    foreach ($files as $file) {
        if (preg_match('~^[^/]+/ext/([^/]+)/~', $file, $match)) {
            $extensions[strtolower($match[1])] = true;
        }
    }

    return $extensions ?: null;
}

/** Version of an extension that is not loaded (xdebug, blackfire), from a PHP process that loads it. */
function versionOfUnloadedExtension(string $file): array
{
    $code = 'foreach (array_merge(get_loaded_extensions(), get_loaded_extensions(true)) as $e) '
        . '{ $v[strtolower($e)] = phpversion($e); } echo json_encode($v);';
    $loaded = array_change_key_case(array_flip(array_merge(get_loaded_extensions(), get_loaded_extensions(true))));
    foreach (['extension', 'zend_extension'] as $directive) {
        $command = escapeshellarg(PHP_BINARY) . ' -d display_errors=stderr -d display_startup_errors=0'
            . ' -d ' . escapeshellarg("$directive=$file") . ' -r ' . escapeshellarg($code) . ' 2>/dev/null';
        $versions = json_decode((string) shell_exec($command), true);
        $new = array_diff_key(is_array($versions) ? $versions : [], $loaded);
        if ($new) {
            return [array_key_first($new), reset($new)];
        }
    }

    return [null, null];
}

/** Installed PEAR packages, by channel and name. */
function pearRegistry(): array
{
    $packages = [];
    $files = array_merge(
        glob(PEAR_INSTALL_DIR . '/.registry/*.reg') ?: [],
        glob(PEAR_INSTALL_DIR . '/.registry/.channel.*/*.reg') ?: []
    );
    foreach ($files as $file) {
        $info = @unserialize((string) file_get_contents($file), ['allowed_classes' => false]);
        if (!is_array($info) || !isset($info['name'])) {
            continue;
        }
        $channel = $info['channel'] ?? PEAR_CHANNEL;
        $license = $info['license'] ?? null;
        $packages[$channel][strtolower($info['name'])] = [
            'name' => $info['name'],
            'version' => $info['version']['release'] ?? null,
            'license' => is_array($license)
                ? license($license['_content'] ?? null, $license['attribs']['uri'] ?? null)
                : license($license),
            'description' => $info['summary'] ?? null,
            'extension' => $info['providesextension'] ?? $info['name'],
        ];
    }

    return $packages;
}

function findComposer(): ?string
{
    foreach (explode(PATH_SEPARATOR, (string) getenv('PATH')) as $dir) {
        if ($dir !== '' && is_file("$dir/composer")) {
            return "$dir/composer";
        }
    }

    return null;
}

$output = $argv[1] ?? DEFAULT_OUTPUT;
// Images rebuilt with a security patch on top of the release (php-backport/ on the older
// branches) keep the release version. The patched CVEs also go into the purl (qualifier
// "backport"): Trivy passes it through to its reports, so a SecObserve rule can mark exactly
// these CVEs of exactly these images as not affected.
$backport = (string) getenv('PHP_SECURITY_BACKPORT');
$backportCves = preg_match_all('/CVE-\d{4}-\d+/', $backport, $matches) ? array_values(array_unique($matches[0])) : [];
$phpRef = purl('bitnami', 'php', PHP_VERSION)
    . ($backportCves ? '?backport=' . rawurlencode(implode(',', $backportCves)) : '');
$components = [];
$dependencies = [$phpRef => []];

// Shared extensions that are not part of the PHP source the image was built from.
$bundled = bundledExtensions();
if ($bundled === null) {
    warn(PHP_SOURCE . ' not found, bundled extensions are told apart by their version only');
}
$sharedFiles = glob(ini_get('extension_dir') . '/*.so') ?: [];
$thirdParty = [];
foreach ($sharedFiles as $file) {
    $name = strtolower(basename($file, '.so'));
    if ($bundled !== null && isset($bundled[$name])) {
        continue;
    }
    // xdebug and blackfire are installed but only loaded on demand
    [$extension, $version] = extension_loaded($name) ? [$name, phpversion($name)] : versionOfUnloadedExtension($file);
    if ($bundled === null && is_string($version) && str_contains($version, PHP_VERSION)) {
        continue;
    }
    $thirdParty[$name] = [$extension, $version];
}
ksort($thirdParty);

// PHP itself; the bundled extensions it has (compiled in or shared) are listed as a property.
$builtIn = array_map('strtolower', array_merge(get_loaded_extensions(), array_map(
    static fn ($file) => basename($file, '.so'),
    $sharedFiles
)));
$builtIn = array_diff(str_replace('zend opcache', 'opcache', $builtIn), array_keys($thirdParty), ['core']);
$builtIn = array_unique($builtIn);
sort($builtIn);
$php = component('application', 'php', PHP_VERSION, $phpRef, [
    'description' => 'PHP ' . PHP_VERSION . ', built from source',
    'licenses' => [license('PHP-3.01')],
    'cpe' => 'cpe:2.3:a:php:php:' . PHP_VERSION . ':*:*:*:*:*:*:*',
    'properties' => [['name' => 'cors:php:bundled-extensions', 'value' => implode(',', $builtIn)]],
]);
// Record the backport (see $backportCves above) in the CycloneDX way as well.
if ($backportCves) {
    $php['pedigree'] = ['patches' => [[
        'type' => 'backport',
        'resolves' => array_map(static fn ($id) => ['type' => 'security', 'id' => $id], $backportCves),
    ]]];
    $php['properties'][] = ['name' => 'cors:php:security-backport', 'value' => $backport];
}
$components[] = $php;

$pear = pearRegistry();
$pecl = [];
foreach ($pear[PECL_CHANNEL] ?? [] as $package) {
    $pecl[strtolower($package['extension'])] = $package;
}
foreach ($thirdParty as $file => [$extension, $version]) {
    $package = $pecl[$file] ?? $pecl[strtolower((string) $extension)] ?? null;
    $properties = [['name' => 'cors:php:extension', 'value' => "$file.so"]];
    // the blackfire probe reports e.g. "2026.10.4~linux-musl-arm64-non_zts84"
    if (is_string($version) && str_contains($version, '~')) {
        $properties[] = ['name' => 'cors:php:extension-version', 'value' => $version];
        $version = strstr($version, '~', true);
    }
    // git builds report a placeholder like "@PACKAGE_VERSION@"
    if (!isVersion($version)) {
        $version = $package['version'] ?? null;
    }
    if ($version === null) {
        warn("no version found for the extension $file, it is listed without one");
    }
    $name = NON_PECL_EXTENSIONS[$file] ?? 'pecl' . $file;
    $ref = purl('bitnami', $name, $version);
    $components[] = component('library', $name, $version, $ref, [
        'description' => $package['description'] ?? null,
        'licenses' => array_filter([$package['license'] ?? null]),
        'properties' => $properties,
    ]);
    $dependencies[$phpRef][] = $ref;
}

// PEAR itself and the libraries it ships with (Archive_Tar, Console_Getopt, ...), installed by
// PHP's "make install". Packagist has them as pear/<name>.
foreach ($pear[PEAR_CHANNEL] ?? [] as $key => $package) {
    $ref = purl('composer', "pear/$key", $package['version']);
    $components[] = component('library', $package['name'], $package['version'], $ref, [
        'group' => 'pear',
        'description' => $package['description'],
        'licenses' => array_filter([$package['license']]),
    ]);
    $dependencies[$phpRef][] = $ref;
}

// composer and the libraries bundled in its phar (symfony/console, ...).
$rootDependencies = [$phpRef];
$composer = findComposer();
if ($composer !== null) {
    $installed = $packages = null;
    // the phar stream wrapper only opens files with a .phar extension
    $phar = tempnam(sys_get_temp_dir(), 'composer') . '.phar';
    try {
        copy($composer, $phar);
        $installed = include "phar://$phar/vendor/composer/installed.php";
        $packages = json_decode((string) file_get_contents("phar://$phar/vendor/composer/installed.json"), true);
    } catch (Throwable $e) {
        warn("$composer is not a readable composer phar: " . $e->getMessage());
    } finally {
        @unlink($phar);
        @unlink(substr($phar, 0, -5));
    }
    $version = $installed['root']['pretty_version'] ?? null;
    if (isVersion($version)) {
        $composerRef = purl('bitnami', 'composer', $version);
        $components[] = component('application', 'composer', $version, $composerRef, [
            'description' => 'Dependency manager for PHP',
            // composer is MIT licensed; its own composer.json is not part of the phar
            'licenses' => [license('MIT')],
            'cpe' => "cpe:2.3:a:getcomposer:composer:$version:*:*:*:*:*:*:*",
            'properties' => [['name' => 'cors:file', 'value' => $composer]],
        ]);
        $rootDependencies[] = $composerRef;
        $dependencies[$composerRef] = [];
        foreach ($packages['packages'] ?? [] as $package) {
            if (!isset($package['name'], $package['version'])) {
                continue;
            }
            $libraryVersion = ltrim($package['version'], 'v');
            $ref = purl('composer', $package['name'], $libraryVersion);
            [$group, $name] = explode('/', $package['name'], 2);
            $components[] = component('library', $name, $libraryVersion, $ref, [
                'group' => $group,
                'description' => $package['description'] ?? null,
                'licenses' => array_values(array_filter(array_map('license', (array) ($package['license'] ?? [])))),
            ]);
            $dependencies[$composerRef][] = $ref;
        }
    } else {
        warn("no composer version found in $composer, composer is not listed");
    }
}

$rootRef = 'php-runtime';
$uuid = random_bytes(16);
$uuid[6] = chr(ord($uuid[6]) & 0x0f | 0x40);
$uuid[8] = chr(ord($uuid[8]) & 0x3f | 0x80);
$uuid = vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($uuid), 4));
$bom = [
    'bomFormat' => 'CycloneDX',
    'specVersion' => '1.5',
    'serialNumber' => 'urn:uuid:' . $uuid,
    'version' => 1,
    'metadata' => [
        'timestamp' => gmdate('Y-m-d\TH:i:s\Z'),
        'tools' => ['components' => [['type' => 'application', 'name' => 'generate-sbom']]],
        'component' => [
            'bom-ref' => $rootRef,
            'type' => 'application',
            'name' => 'php-runtime',
            'version' => PHP_VERSION,
            'description' => 'PHP runtime components installed outside the apk package database',
        ],
    ],
    'components' => $components,
    'dependencies' => array_merge(
        [['ref' => $rootRef, 'dependsOn' => $rootDependencies]],
        array_map(
            static fn ($ref, $dependsOn) => ['ref' => $ref, 'dependsOn' => $dependsOn],
            array_keys($dependencies),
            array_values($dependencies)
        ),
        array_map(
            static fn ($component) => ['ref' => $component['bom-ref'], 'dependsOn' => []],
            array_filter($components, static fn ($component) => !isset($dependencies[$component['bom-ref']]))
        )
    ),
];

if (!is_dir(dirname($output)) && !mkdir(dirname($output), 0755, true)) {
    fwrite(STDERR, "generate-sbom: cannot create " . dirname($output) . "\n");
    exit(1);
}
file_put_contents($output, json_encode($bom, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");

foreach ($components as $component) {
    printf("%-40s %s\n", $component['purl'], implode(',', array_map(
        static fn ($l) => $l['license']['id'] ?? $l['license']['name'] ?? '',
        $component['licenses'] ?? []
    )));
}
echo "SBOM with " . count($components) . " components written to $output\n";
