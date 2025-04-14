import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react-swc";
import Pages from "vite-plugin-pages";
import path from "path";

export default defineConfig(({ command, mode }) => {
 const env = loadEnv(mode, process.cwd(), '');
 
 return {
   plugins: [
     react(),
     Pages({
       dirs: "src/routes",
       extensions: ["tsx"],
     }),
   ],
   define: {
     'import.meta.env.VITE_API_URL': JSON.stringify(env.VITE_API_URL),
   },
   build: {
     outDir: "dist",
     minify: 'terser',
     target: "esnext",
     sourcemap: true,
     rollupOptions: {
       output: {
         manualChunks: {
           'react-vendor': ['react', 'react-dom'],
           'ui-vendor': ['@radix-ui/themes', '@radix-ui/react-icons'],
         },
       },
     },
     terserOptions: {
       compress: {
         drop_console: false,
         drop_debugger: false,
         pure_funcs: [],
         pure_getters: true,
         passes: 2,
         unsafe_math: false,
         unsafe_methods: false,
       },
       mangle: {
         toplevel: false,
         properties: false,
       },
       format: {
         comments: false,
         ascii_only: true,
         wrap_iife: true,
       },
     },
     chunkSizeWarningLimit: 1000,
   },
   resolve: {
     alias: {
       "@": path.resolve(__dirname, "./src"),
     },
     extensions: [".ts", ".tsx", ".js", ".jsx", ".json"],
   },
   publicDir: 'public', // This is the default, but explicitly including for clarity
   esbuild: {
     drop: [],
     pure: [],
     legalComments: 'none',
     treeShaking: true,
   },
   // Add Vitest configuration here
   test: {
     environment: 'jsdom',
     globals: true,
     include: ['**/*.{test,spec}.{ts,tsx}'],
     coverage: {
       reporter: ['text', 'json', 'html'],
     },
   },
 }
});