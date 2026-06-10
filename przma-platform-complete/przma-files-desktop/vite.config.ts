import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri serves the dev server from this fixed port (matches tauri.conf.json devUrl).
export default defineConfig({
  plugins: [react()],
  // Don't clear the screen so Rust/cargo logs stay visible during `tauri dev`.
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "esnext",
  },
});
