import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
export default defineConfig({
  base: './',
  plugins: [vue()],
  build: { rollupOptions: { input: { local: 'index.html', hosted: 'hosted.html' } } },
})
