import { defineConfig } from "vite";

export default defineConfig({
  root: "src",
  base: "./",
  build: {
    outDir: "../dist",
    emptyOutDir: true,
    assetsDir: ".",
    rollupOptions: {
      input: "index.html",
      output: {
        entryFileNames: "editor.js",
        chunkFileNames: "editor-[hash].js",
        assetFileNames: "editor.[ext]"
      }
    }
  }
});
