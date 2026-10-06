import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class PipelineTests(unittest.TestCase):
    def test_cla_records_require_account_and_version(self):
        subprocess.run(['node', '-e', '''
const assert = require('node:assert/strict');
const {hasSigned} = require('./.github/scripts/cla.cjs');
const records=[{login:'alice',version:'1.0',comment_url:'https://github.com/example/pr#comment'}];
assert.equal(hasSigned(records,'alice'),true);
assert.equal(hasSigned(records,'bob'),false);
assert.equal(hasSigned([{...records[0],version:'2.0'}],'alice'),false);
assert.equal(hasSigned([{...records[0],comment_url:''}],'alice'),false);
assert.equal(hasSigned([],'SwallOwDili'),false);
assert.equal(hasSigned([],'bot-fake'),false);
'''], cwd=ROOT, check=True)

    def test_cla_missing_contributor_blocks_and_exact_reply_records(self):
        subprocess.run(['node', '-e', r'''
const assert=require('node:assert/strict');
const {check,phrase}=require('./.github/scripts/cla.cjs');
let records=[], saved, lastState, comments=0;
const pr={state:'open',user:{login:'alice'},head:{sha:'a'.repeat(40)},commits:1,html_url:'https://github.com/fixture/fixture/pull/1'};
const github={rest:{pulls:{get:async()=>({data:pr}),listCommits:'commits'},issues:{listComments:'comments',createComment:async()=>{comments++},updateComment:async()=>{}},repos:{getContent:async()=>({data:{content:Buffer.from(JSON.stringify(records)).toString('base64'),sha:'existing'}}),createCommitStatus:async o=>{lastState=o.state},createOrUpdateFileContents:async o=>{saved=JSON.parse(Buffer.from(o.content,'base64').toString());records=saved}},git:{getRef:async()=>({})}},paginate:async method=>method==='commits' ? [{author:{login:'alice',id:7}}] : []};
const context={repo:{owner:'fixture',repo:'fixture'},payload:{comment:{body:phrase,user:{login:'mallory',id:9,type:'User'},html_url:'https://github.com/fixture/fixture/pull/1#comment',created_at:'2026-10-06T00:00:00Z'}}};
(async()=>{
 await assert.rejects(check({github,context,number:1,signing:true}),/CLA signature/);
 assert.equal(saved,undefined);assert.equal(lastState,'failure');
 context.payload.comment.user={login:'alice',id:7,type:'User'};
 await check({github,context,number:1,signing:true});
 assert.equal(saved[0].login,'alice');assert.equal(saved[0].version,'1.0');assert.equal(lastState,'success');
 await check({github,context,number:1});
 assert.equal(lastState,'success');assert.ok(comments>=2);
})().catch(e=>{console.error(e.message);process.exitCode=1});
'''],cwd=ROOT,check=True)

    def test_first_signature_initializes_nonempty_tree(self):
        subprocess.run(['node', '-e', r'''
const assert=require('node:assert/strict');
const {check,phrase}=require('./.github/scripts/cla.cjs');
const missing=()=>{throw Object.assign(new Error('Not found'),{status:404});};
let initialized=false,record;
const github={rest:{pulls:{get:async()=>({data:{state:'open',user:{login:'alice'},head:{sha:'a'.repeat(40)},commits:1,html_url:'https://github.com/fixture/fixture/pull/1'}}),listCommits:'commits'},issues:{listComments:'comments',createComment:async()=>{}},repos:{getContent:async()=>missing(),createCommitStatus:async()=>{},createOrUpdateFileContents:async o=>{assert.equal(initialized,true);record=JSON.parse(Buffer.from(o.content,'base64').toString());}},git:{getRef:async()=>missing(),createTree:async o=>{assert.ok(o.tree.length>0,'GitHub rejects empty trees');assert.equal(o.tree[0].path,'.gitkeep');return {data:{sha:'tree'}}},createCommit:async o=>{assert.deepEqual(o.parents,[]);return {data:{sha:'commit'}}},createRef:async o=>{assert.equal(o.ref,'refs/heads/cla-signatures');initialized=true;}}},paginate:async method=>method==='commits'?[{author:{login:'alice',id:7}}]:[]};
const context={repo:{owner:'fixture',repo:'fixture'},payload:{comment:{body:phrase,user:{login:'alice',id:7,type:'User'},html_url:'https://github.com/fixture/fixture/pull/1#comment',created_at:'2026-10-06T00:00:00Z'}}};
(async()=>{await check({github,context,number:1,signing:true});assert.equal(record[0].login,'alice');})().catch(e=>{console.error(e);process.exitCode=1});
'''],cwd=ROOT,check=True)

    def test_packaging_checks_latest_status_and_trusted_creator(self):
        subprocess.run(['node', '-e', r'''
const assert=require('node:assert/strict');
const {hasAcceptedStatus}=require('./.github/scripts/cla.cjs');
let statuses=[];
const github={rest:{repos:{listCommitStatusesForRef:'statuses'}},paginate:async(method,args)=>{assert.equal(method,'statuses');assert.equal(args.ref,'head');return statuses}};
const accepted={context:'CLA',state:'success',creator:{login:'github-actions[bot]'}};
(async()=>{
assert.equal(await hasAcceptedStatus(github,{},'head'),false);
statuses=[{context:'CLA',state:'success'}];assert.equal(await hasAcceptedStatus(github,{},'head'),false);
statuses=[{...accepted,creator:{login:'untrusted'}}];assert.equal(await hasAcceptedStatus(github,{},'head'),false);
statuses=[{...accepted,state:'failure'},accepted];assert.equal(await hasAcceptedStatus(github,{},'head'),false);
statuses=[accepted];assert.equal(await hasAcceptedStatus(github,{},'head'),true);
})().catch(e=>{console.error(e);process.exitCode=1});
'''],cwd=ROOT,check=True)

if __name__ == '__main__': unittest.main()
