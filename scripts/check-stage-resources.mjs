import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const app = process.argv[2];
assert.ok(app, 'pass the built .app directory');
const source = 'Haru/Resources';
assert.deepEqual(readFileSync(join(app, 'stage.html')), readFileSync(join(source, 'stage.html')));
const faces = readdirSync(join(source, 'emotions')).filter(name => name.endsWith('.svg')).sort();
assert.ok(faces.includes('neutral.svg'));
assert.deepEqual(readdirSync(join(app, 'emotions')).filter(name => name.endsWith('.svg')).sort(), faces);
for (const face of faces) assert.deepEqual(readFileSync(join(app, 'emotions', face)), readFileSync(join(source, 'emotions', face)), face);
console.log(`Verified embedded renderer and all ${faces.length} expression files in the built app`);
