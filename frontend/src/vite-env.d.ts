interface ImportMetaEnv {
  readonly VITE_API_URL: string;
  readonly VITE_NETWORK?: string;
  // Add other env variables you use
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
