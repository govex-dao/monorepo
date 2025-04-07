// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
interface ImportMetaEnv {
  readonly VITE_API_URL: string;
  // Add other env variables you use
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
