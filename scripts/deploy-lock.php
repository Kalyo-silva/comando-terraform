<?php

// Wait for the caller to duplicate the coprocess pipes before opening the session.
if (fgets(STDIN) !== "start\n") {
    exit(1);
}
try {
    $dsn = sprintf(
        'pgsql:host=%s;port=%s;dbname=%s;sslmode=%s;sslrootcert=%s;connect_timeout=5;options=--statement_timeout=5000',
        getenv('DB_HOST'), getenv('DB_PORT') ?: '5432', getenv('DB_DATABASE'),
        getenv('DB_SSLMODE') ?: 'verify-full', getenv('DB_SSLROOTCERT')
    );
    $pdo = new PDO($dsn, getenv('DB_USERNAME'), getenv('DB_PASSWORD'), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    if (!$pdo->query('SELECT pg_try_advisory_lock(2026111701)')->fetchColumn()) {
        echo "busy\n";
        exit(1);
    }
    echo "locked\n";
    while (($command = fgets(STDIN)) === "check\n") {
        $pdo->query('SELECT 1');
        echo "locked\n";
    }
} catch (Throwable) {
    echo "unavailable\n";
    exit(1);
}
