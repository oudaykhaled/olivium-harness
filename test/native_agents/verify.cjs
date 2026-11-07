// Runs only in the credential-free, network-none, read-only test container.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const readline = require('node:readline');
const {spawn, spawnSync} = require('node:child_process');
const codexRoot = '/workspace/exports/codex';
const claudeRoot = '/workspace/exports/claude_code';
assert.equal(process.getuid(), 1000);
assert.equal(process.env.HOME, '/home/node');
for (const name of ['OPENAI_API_KEY','CODEX_API_KEY','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN']) assert(!process.env[name]);
assert(!fs.existsSync('/var/run/docker.sock'));
fs.mkdirSync('/home/node/.codex', {recursive:true});
fs.writeFileSync('/home/node/.codex/config.toml', `[projects."${codexRoot}"]\ntrust_level = "trusted"\n`);
function run(command,args,cwd) {
  const result=spawnSync(command,args,{cwd,encoding:'utf8',timeout:20000,maxBuffer:2097152});
  if (result.error || result.status !== 0) throw new Error(`${command} ${args.join(' ')} failed (${result.status}): ${result.stderr || result.stdout || result.error}`);
  return result.stdout;
}
function digest(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function files(root, paths) { return paths.map(path=>({path,sha256:digest(fs.readFileSync(`${root}/${path}`))})); }
async function codexDiscovery() {
  const negativeRoot='/tmp/codex-negative';
  fs.cpSync(codexRoot,negativeRoot,{recursive:true});
  fs.writeFileSync(`${negativeRoot}/.codex/agents/go-reviewer.toml`,'name = [');
  fs.appendFileSync('/home/node/.codex/config.toml',`[projects."${negativeRoot}"]\ntrust_level = "trusted"\n`);
  const child=spawn('codex',['--no-daemon','-C',codexRoot,'app-server','--stdio'],{cwd:codexRoot,detached:true,stdio:['pipe','pipe','pipe']});
  const pending=new Map(), notifications=[];
  let seq=0,stderr='';
  child.stderr.on('data',bytes=>{ stderr=(stderr+bytes).slice(-16384); });
  child.on('error',error=>{ for (const item of pending.values()) item.reject(error); });
  readline.createInterface({input:child.stdout}).on('line',line=>{
    const message=JSON.parse(line);
    const item=pending.get(message.id);
    if(item) { pending.delete(message.id); clearTimeout(item.timer); message.error ? item.reject(new Error(JSON.stringify(message.error))) : item.resolve(message.result); }
    else notifications.push(message);
  });
  function request(method,params) {
    return new Promise((resolve,reject)=>{
      const id=++seq;
      const timer=setTimeout(()=>{pending.delete(id);reject(new Error(`${method} timed out: ${stderr}`));},10000);
      pending.set(id,{resolve,reject,timer});
      child.stdin.write(JSON.stringify({id,method,params})+'\n');
    });
  }
  try {
    await request('initialize',{clientInfo:{name:'harnessforge_native_probe',version:'0.1.0'},capabilities:{experimentalApi:true}});
    child.stdin.write(JSON.stringify({method:'initialized'})+'\n');
    const effective=await request('config/read',{cwd:codexRoot,includeLayers:true});
    assert.equal(effective.config.features.shell_tool,false);
    assert.equal(effective.config.sandbox_workspace_write.network_access,false);
    assert.equal(effective.config.approval_policy,'on-request');
    assert.equal(effective.origins['features.shell_tool'].name.dotCodexFolder,`${codexRoot}/.codex`);
    const skills=await request('skills/list',{cwds:[codexRoot],forceReload:true});
    const skill=skills.data.find(item=>item.cwd===codexRoot).skills.find(item=>item.name==='table-tests');
    assert.equal(skill.path,`${codexRoot}/.agents/skills/table-tests/SKILL.md`);
    assert.equal(skill.enabled,true);
    const valid=await request('thread/start',{cwd:codexRoot,ephemeral:true});
    assert(valid.instructionSources.includes(`${codexRoot}/AGENTS.md`));
    assert.equal(valid.sandbox.networkAccess,false);
    assert.equal(valid.approvalPolicy,'on-request');
    assert(!notifications.some(item=>/malformed agent role/i.test(JSON.stringify(item))));
    await request('thread/start',{cwd:negativeRoot,ephemeral:true});
    const malformed=notifications.find(item=>item.method==='configWarning' && item.params.summary.includes(`${negativeRoot}/.codex/agents/go-reviewer.toml`));
    assert(malformed,'Native startup must detect the malformed agent file');
    assert(malformed.params.summary.includes('TOML parse error'));
    return {configRead:true,projectConfigOrigin:`${codexRoot}/.codex`,instructionSources:valid.instructionSources,skill:{name:skill.name,path:skill.path,enabled:skill.enabled},agentFileNativeParserVerified:true,malformedAgentRejected:true,negativeControlDiagnostic:malformed.params.summary,turnsStarted:0,agentInvocationVerified:false};
  } finally {
    for (const item of pending.values()) clearTimeout(item.timer);
    const stop=signal=>{ try { process.kill(-child.pid,signal); } catch(error) { if(error.code!=='ESRCH') throw error; } };
    stop('SIGTERM');
    await new Promise(resolve=>{ if(child.exitCode!==null)resolve(); else {const timer=setTimeout(()=>{stop('SIGKILL');resolve();},2000);child.once('exit',()=>{clearTimeout(timer);resolve();});} });
  }
}
function claudeStartup(root) {
  // Empty setting sources also suppress project agents/skills in this version.
  // Only the synthetic project is enabled; no host/user/local settings are mounted.
  const args=['--settings',`${root}/.claude/settings.json`,'--setting-sources','project','--strict-mcp-config','--no-chrome','--no-session-persistence','--permission-prompts','none','--print','HARNESSFORGE_OFFLINE_PROMPT_SENTINEL','--output-format','stream-json','--verbose'];
  const result=spawnSync('claude',args,{cwd:root,encoding:'utf8',timeout:20000,maxBuffer:2097152});
  assert(!result.error, String(result.error));
  assert.equal(result.status,1,'Credential-free startup must refuse inference');
  const events=result.stdout.split('\n').filter(Boolean).map(line=>JSON.parse(line));
  const init=events.find(item=>item.type==='system' && item.subtype==='init');
  const terminal=events.find(item=>item.type==='result');
  assert(init && terminal,'Native startup/result records are required');
  assert.equal(init.apiKeySource,'none');
  assert.equal(terminal.is_error,true);
  assert.match(terminal.result,/Not logged in/);
  assert.equal(terminal.duration_api_ms,0);
  assert.equal(terminal.total_cost_usd,0);
  assert.equal(terminal.usage.input_tokens,0);
  assert.equal(terminal.usage.output_tokens,0);
  assert.deepEqual(terminal.modelUsage,{});
  assert.deepEqual(init.mcp_servers,[]);
  assert(!init.tools.includes('Bash'));
  return {init,terminal};
}
async function main() {
  const codexVersion=run('codex',['--version'],codexRoot).trim();
  const claudeVersion=run('claude',['--version'],claudeRoot).trim();
  assert.equal(codexVersion,'codex-cli 0.156.0');
  assert.equal(claudeVersion,'2.1.311 (Claude Code)');
  const features=run('codex',['--no-daemon','-C',codexRoot,'features','list'],codexRoot);
  assert(features.split('\n').some(line=>line.startsWith('shell_tool') && line.trim().endsWith('false')));
  const prompt=run('codex',['--no-daemon','-C',codexRoot,'debug','prompt-input','HARNESSFORGE_OFFLINE_PROMPT_SENTINEL'],codexRoot);
  assert(prompt.includes('HARNESSFORGE_NATIVE_RULE_SENTINEL'));
  assert(prompt.includes('table-tests'));
  const codex=await codexDiscovery();
  const claude=claudeStartup(claudeRoot);
  assert(claude.init.agents.includes('go-reviewer'));
  assert(claude.init.skills.includes('table-tests'));
  assert(claude.init.slash_commands.includes('table-tests'));
  const negativeRoot='/tmp/claude-negative';
  fs.cpSync(claudeRoot,negativeRoot,{recursive:true});
  fs.rmSync(`${negativeRoot}/.claude/agents/go-reviewer.md`);
  fs.rmSync(`${negativeRoot}/.claude/skills/table-tests`,{recursive:true});
  const negative=claudeStartup(negativeRoot);
  assert(!negative.init.agents.includes('go-reviewer'));
  assert(!negative.init.skills.includes('table-tests'));
  console.log(JSON.stringify({
    codexVersion,claudeVersion,
    codex:{...codex,guidanceSentinelDiscovered:true,promptDigest:digest(prompt),files:files(codexRoot,['AGENTS.md','.codex/config.toml','.codex/agents/go-reviewer.toml','.agents/skills/table-tests/SKILL.md'])},
    claude:{startupDiscovery:true,agents:['go-reviewer'],skills:['table-tests'],skillSlashCommandDiscovered:true,fileRemovalNegativeControl:true,settingsFile:`${claudeRoot}/.claude/settings.json`,settingSources:['project'],bashToolAbsent:true,mcpServers:[],authenticationRefused:true,apiDurationMs:claude.terminal.duration_api_ms,inputTokens:claude.terminal.usage.input_tokens,outputTokens:claude.terminal.usage.output_tokens,totalCostUsd:claude.terminal.total_cost_usd,pluginValidatorUsed:false,files:files(claudeRoot,['.claude/settings.json','.claude/agents/go-reviewer.md','.claude/skills/table-tests/SKILL.md'])},
    network:'none',credentials:false,modelCalls:false,repositoryCodeExecuted:false,agentInvocationVerified:false,skillInvocationVerified:false,runtimeQualified:false,
    limits:['Native file discovery and parser/startup checks only. No authenticated inference, coding task, agent invocation or skill invocation.','Claude plugin validate returned empty contents and is not counted as file validation.','Codex startup reports bundled bubblewrap fallback; sandbox execution is not qualified by this probe.']
  },null,2));
}
main().catch(error=>{console.error(error.stack);process.exitCode=1;});
