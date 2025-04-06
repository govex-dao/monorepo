// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { publishPackage } from '../publish-utils';
import fs from 'fs';
import path from 'path';

(async () => {
    const packagePath = path.resolve(__dirname + '/../../contracts/futarchy');
    
    // Remove the build directory if it exists
    const buildPath = path.join(packagePath, 'build');
    if (fs.existsSync(buildPath)) {
        fs.rmSync(buildPath, { recursive: true });
        console.log('Removed old build directory');
    }

    // Remove Move.lock if it exists
    const lockPath = path.join(packagePath, 'Move.lock');
    if (fs.existsSync(lockPath)) {
        fs.unlinkSync(lockPath);
        console.log('Removed Move.lock file');
    }
    await publishPackage({
        packagePath: __dirname + '/../../contracts/futarchy',
        network: 'testnet',
        exportFileName: 'futarchy-contract',
    });
    
})();
