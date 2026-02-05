import * as esbuild from 'esbuild';

const entryPoints = ['src/main.js'];

const watch = process.argv.includes('--watch');

const config = {
    entryPoints,
    bundle: true,
    outdir: 'dist',
    format: 'esm',
    platform: 'neutral',
    external: ['k6', 'k6/*', 'https://*'],
    sourcemap: true,
};

if (watch) {
    const ctx = await esbuild.context(config);
    await ctx.watch();
    console.log('Watching for changes...');
} else {
    await esbuild.build(config);
    console.log('Build complete');
}
