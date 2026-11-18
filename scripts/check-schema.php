<?php

// Run in the candidate image. Compare migration names without changing the database.
try {
    require 'vendor/autoload.php';
    $app = require 'bootstrap/app.php';
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    $migrator = $app->make('migrator');
    $repository = $migrator->getRepository();
    if (!$repository->repositoryExists()) {
        exit(1);
    }
    $expected = array_keys($migrator->getMigrationFiles(
        array_merge($migrator->paths(), [$app->databasePath('migrations')])
    ));
    $applied = $repository->getRan();
    exit(array_diff($expected, $applied) || array_diff($applied, $expected) ? 1 : 0);
} catch (Throwable) {
    exit(1);
}
