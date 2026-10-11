<?php
// misp-router: the front for PHP's built-in server. An existing file is
// served as itself. Anything else is MISP's index. A path with ".." is
// refused. PHP is bound to loopback; Caddy is what the network sees.
$path = parse_url($_SERVER["REQUEST_URI"] ?? "/", PHP_URL_PATH);
if (!is_string($path) || str_contains($path, "..")) {
    http_response_code(400);
    return true;
}
$file = "/var/www/MISP/app/webroot" . $path;
if ($path !== "/" && is_file($file)) {
    return false;
}
require "/var/www/MISP/app/webroot/index.php";
