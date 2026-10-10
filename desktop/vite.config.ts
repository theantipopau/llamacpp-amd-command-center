import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri loads devUrl from a fixed loopback origin, so the port must not move.
// Assets are bundled for the WebView2 runtime the app ships against.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "chrome110"
  }
});
