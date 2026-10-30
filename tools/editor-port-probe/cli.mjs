import { readFileSync, writeFileSync } from 'node:fs';
import { envelope } from './oracle.mjs';
import { fixtures } from './fixtures.mjs';
try {
 const generate=process.argv[2]==='--generate';
 const input=generate?fixtures:JSON.parse(readFileSync(process.argv[2]||0,'utf8'));
 const cases=Array.isArray(input)?input:(input.cases||[input]);
 const result=envelope(cases);
 const json=JSON.stringify(result,null,2)+'\n';
 if(generate){writeFileSync(new URL('./oracle-fixtures.v1.json',import.meta.url),json);console.log(`已生成 ${cases.length} 个官方样例`);}else process.stdout.write(json);
 if(result.cases.some(c=>c.status==='error'))process.exitCode=1;
}catch(e){process.stdout.write(JSON.stringify({version:1,status:'error',error:{stage:'input',message:e.message}})+'\n');process.exitCode=1;}
