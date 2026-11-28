import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
const {createDeviceServer}=await import(pathToFileURL(resolve(process.env.FLUXDO_PLUGIN_TOOLS,'packages/cli/dist/dev/session.mjs')).href);
const server=await createDeviceServer({root:process.argv[2],port:0});
console.log(server.url);
process.stdin.resume();process.stdin.on('end',()=>void server.close());
