interface ImportMetaEnv {
  readonly VITE_API_URL: string;
  // Add other env variables you use
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
