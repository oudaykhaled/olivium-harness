'use strict';
// Source-owned zero-turn app-server discovery; no turn/start or tool invocation.
// Reuses test/native_agents/verify.cjs and pinned native bridge contract03 DTOs.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const readline = require('node:readline');
const {spawn, spawnSync} = require('node:child_process');
const root = '/candidate';
const home = '/home/harnessforge/.codex';
const maxBytes = 131072;
let phase = 'container-metadata';
let nativeErrorCode = null;
let observedRawPolicy = null;
let observedBootstrapPolicy = null;
const ruleRoots = ['/etc/codex/rules',`${home}/rules`,`${root}/.codex/rules`];
const disabled = ['apps','browser_use','browser_use_external','browser_use_full_cdp_access',
  'code_mode','code_mode_host','code_mode_only','computer_use','goals','hooks','image_generation',
  'in_app_browser','in_app_chat','in_app_local_automation','memories','multi_agent','multi_agent_v2',
  'plugins','remote_plugin','remote_models','shell_snapshot','shell_snapshot_v2','unified_exec',
  'unified_exec_tty','shell_zsh_fork','exec_permission_approvals','request_permissions_tool',
  'view_image','use_legacy_landlock','skill_mcp_dependency_install','skill_env_var_dependency_prompt',
  'enable_request_compression','unbounded_connection_retries','network_proxy'];
const enabled = ['shell_tool'];
const managedFeatures = Object.fromEntries(['unified_exec','unified_exec_tty','shell_zsh_fork',
  'shell_snapshot','shell_snapshot_v2','hooks','exec_permission_approvals','request_permissions_tool',
  'view_image','use_legacy_landlock'].map(key => [key,false]));
managedFeatures.shell_tool = true;
const shellEnvironment = {inherit:'none',ignore_default_excludes:false,
  exclude:['HARNESSFORGE_RELAY_TOKEN','HARNESSFORGE_*','*TOKEN*','*KEY*','*SECRET*'],
  include_only:['PATH','HOME','TMPDIR','LANG','SHELL'],
  set:{PATH:'/usr/local/bin:/usr/bin:/bin',HOME:root,TMPDIR:root,LANG:'C.UTF-8',SHELL:'/bin/bash'}};
const provider = {base_url:'http://model-relay:8080/v1',env_key:'HARNESSFORGE_RELAY_TOKEN',
  wire_api:'responses',requires_openai_auth:false,request_max_retries:0,stream_max_retries:0};
const fixed = [
  ['model_provider','harnessforge_local'],['approvals_reviewer','user'],
  ['default_permissions','hf_candidate'],['allow_login_shell',false],['tool_output_token_limit',2000],
  ['tools.experimental_request_user_input.enabled',false],['tools.update_plan.enabled',false],
  ['web_search','disabled'],['skills.bundled.enabled',false],
  ['model_providers.harnessforge_local.name','HarnessForge isolated local relay'],
  ...Object.entries(provider).sort().map(([key,value]) => [`model_providers.harnessforge_local.${key}`,value]),
  ...disabled.map(key => [`features.${key}`,false]),...enabled.map(key => [`features.${key}`,true]),
  ['features.skip_host_skill_discovery',true],
  ...Object.entries(shellEnvironment).filter(([key]) => key !== 'set').sort()
    .map(([key,value]) => [`shell_environment_policy.${key}`,value]),
  ...Object.entries(shellEnvironment.set).sort().map(([key,value]) => [`shell_environment_policy.set.${key}`,value])
];
const overrides = fixed.flatMap(([key,value]) => ['-c',`${key}=${JSON.stringify(value)}`]);
const originKeys = ['model','model_provider','approval_policy','approvals_reviewer','default_permissions',
  'web_search','features.shell_tool','features.unified_exec','features.multi_agent','features.hooks',
  'shell_environment_policy.inherit','tools.experimental_request_user_input.enabled','tools.update_plan.enabled'];
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function plain(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function file(name) {
  const stat = fs.lstatSync(name);
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.size <= maxBytes);
  return fs.readFileSync(name);
}
function expectedInput() {
  const value = JSON.parse(file('/runtime/preflight-expected.json'));
  assert.deepEqual(Object.keys(value).sort(),
    ['guidance_sha256','model','overlay_sha256','project_config_sha256','requirements_sha256','rule_directory_uids','skill_paths'].sort());
  assert(typeof value.model === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,127}$/.test(value.model));
  for (const key of ['guidance_sha256','overlay_sha256','project_config_sha256','requirements_sha256'])
    assert(/^[a-f0-9]{64}$/.test(value[key]));
  assert(Array.isArray(value.skill_paths) && value.skill_paths.length <= 100);
  assert.deepEqual(value.skill_paths,[...new Set(value.skill_paths)].sort());
  for (const name of value.skill_paths)
    assert(/^\/candidate\/\.agents\/skills\/[a-z0-9]+(?:-[a-z0-9]+)*\/SKILL\.md$/.test(name));
  assert(plain(value.rule_directory_uids));
  assert.deepEqual(Object.keys(value.rule_directory_uids).sort(),[...ruleRoots].sort());
  for (const name of ruleRoots) assert.equal(value.rule_directory_uids[name],0);
  return value;
}
function immutableRules(owners) {
  return ruleRoots.map(name => {
    const stat = fs.lstatSync(name);
    assert(stat.isDirectory() && !stat.isSymbolicLink() && fs.realpathSync(name) === name);
    assert.equal(stat.uid,owners[name]);
    assert.equal(stat.mode & 0o777,0o555);
    const entries = fs.readdirSync(name);
    assert.deepEqual(entries,[]);
    assert.throws(() => fs.accessSync(name,fs.constants.W_OK));
    return {path:name,uid:stat.uid,mode:stat.mode & 0o777,entries,writable:false};
  });
}
function loadedRules(layers) {
  assert(Array.isArray(layers) && layers.length > 0 && layers.length <= 16);
  const roots = [];
  for (const layer of layers) {
    assert(plain(layer) && plain(layer.name));
    // The upstream loader excludes disabled layers from exec-policy loading.
    if (layer.disabledReason) continue;
    const name = layer.name;
    let folder;
    if (name.type === 'sessionFlags' || name.type === 'packagedDefaults') continue;
    if (name.type === 'system') {
      assert.equal(name.file,'/etc/codex/config.toml');
      folder = path.dirname(name.file);
    } else if (name.type === 'user') {
      assert.equal(name.file,`${home}/config.toml`);
      assert.equal(name.profile,null);
      folder = path.dirname(name.file);
    } else if (name.type === 'project') {
      assert.equal(name.dotCodexFolder,`${root}/.codex`);
      folder = name.dotCodexFolder;
    } else throw new Error('Unqualified native configuration layer');
    const policy = `${folder}/rules`;
    assert(ruleRoots.includes(policy));
    roots.push(policy);
  }
  const result = [...new Set(roots)].sort();
  assert.deepEqual(result,[...ruleRoots].sort());
  return result;
}
async function main() {
  assert.equal(process.getuid(),65534);
  assert.equal(process.env.HOME,'/home/harnessforge');
  assert.equal(process.env.CODEX_HOME,home);
  for (const key of ['OPENAI_API_KEY','CODEX_API_KEY','ANTHROPIC_API_KEY',
    'ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN']) assert(!process.env[key]);
  assert(!fs.existsSync('/var/run/docker.sock') && !fs.existsSync(`${home}/auth.json`));
  assert(fs.statSync('/bin/bash').isFile());
  fs.accessSync('/bin/bash',fs.constants.X_OK);
  const expected = expectedInput();
  assert.equal(hash(file(`${home}/config.toml`)),expected.overlay_sha256);
  assert.equal(hash(file(`${root}/AGENTS.md`)),expected.guidance_sha256);
  assert.equal(hash(file(`${root}/.codex/config.toml`)),expected.project_config_sha256);
  assert.equal(hash(file('/etc/codex/requirements.toml')),expected.requirements_sha256);
  const requirementsStat = fs.lstatSync('/etc/codex/requirements.toml');
  assert.equal(fs.realpathSync('/etc/codex/requirements.toml'),'/etc/codex/requirements.toml');
  assert.equal(requirementsStat.uid,0);
  assert.equal(requirementsStat.mode & 0o777,0o444);
  assert.throws(() => fs.accessSync('/etc/codex/requirements.toml',fs.constants.W_OK));
  phase = 'managed-files-and-rules';
  const rules = immutableRules(expected.rule_directory_uids);
  phase = 'native-version';
  const version = spawnSync('codex',['--version'],{encoding:'utf8',timeout:5000,maxBuffer:4096});
  assert(!version.error && version.status === 0 && version.stderr === '');
  assert.equal(version.stdout,'codex-cli 0.156.0\n');
  const argv = ['--no-daemon','--strict-config','-C',root,...overrides,'app-server','--stdio'];
  const child = spawn('codex',argv,{cwd:root,detached:true,stdio:['pipe','pipe','pipe']});
  const pending = new Map(), notifications = [];
  let seq = 0, received = 0, stderr = '', protocolError = null;
  const fail = () => {
    protocolError = new Error('Native discovery protocol rejected');
    for (const item of pending.values()) item.reject(protocolError);
  };
  child.stderr.on('data',bytes => {stderr += bytes; if (Buffer.byteLength(stderr) > 8192) fail();});
  child.on('error',fail);
  child.on('exit',() => {if (pending.size) fail();});
  readline.createInterface({input:child.stdout}).on('line',line => {
    received += Buffer.byteLength(line) + 1;
    if (received > maxBytes || notifications.length > 1000) return fail();
    let message;
    try {message = JSON.parse(line);} catch {return fail();}
    if (!plain(message)) return fail();
    if (message.method && Object.hasOwn(message,'id')) return fail();
    const item = pending.get(message.id);
    if (item) {
      pending.delete(message.id); clearTimeout(item.timer);
      if (message.error) {
        nativeErrorCode = Number.isInteger(message.error.code) ? message.error.code : null;
        item.reject(new Error('Native discovery request rejected'));
      } else item.resolve(message.result);
    } else notifications.push(message);
  });
  function request(method,params) {
    phase = method;
    assert(!protocolError);
    return new Promise((resolve,reject) => {
      const id = ++seq;
      const timer = setTimeout(() => {pending.delete(id);reject(new Error('Native discovery timeout'));},10000);
      pending.set(id,{resolve,reject,timer});
      child.stdin.write(JSON.stringify({id,method,params}) + '\n');
    });
  }
  try {
    const initialize = await request('initialize',{clientInfo:{name:'harnessforge_runtime_preflight',version:'3.0.0'},capabilities:{experimentalApi:true}});
    assert.equal(initialize.codexHome,home);
    assert.equal(initialize.platformFamily,'unix');
    assert.equal(initialize.platformOs,'linux');
    assert(typeof initialize.userAgent === 'string' && initialize.userAgent.length > 0 && initialize.userAgent.length <= 256);
    child.stdin.write(JSON.stringify({method:'initialized'}) + '\n');
    const effective = await request('config/read',{cwd:root,includeLayers:true});
    const config = effective.config;
    assert(plain(config) && plain(effective.origins));
    assert.equal(config.model,expected.model);
    assert.equal(config.model_provider,'harnessforge_local');
    // Raw immutable project defaults differ from the effective managed thread
    // policy. The pinned binary rejects untrusted in TOML/session -c settings.
    assert.equal(config.approval_policy,'on-request');
    observedRawPolicy = config.approval_policy;
    assert.equal(config.approvals_reviewer,'user');
    assert.equal(config.default_permissions,'hf_candidate');
    assert.equal(config.allow_login_shell,false);
    assert.equal(config.tool_output_token_limit,2000);
    assert.equal(config.web_search,'disabled');
    assert.equal(config.skills.bundled.enabled,false);
    assert.deepEqual(config.shell_environment_policy,shellEnvironment);
    const actualProvider = config.model_providers.harnessforge_local;
    for (const [key,value] of Object.entries(provider)) assert.equal(actualProvider[key],value);
    assert.equal(actualProvider.name,'HarnessForge isolated local relay');
    assert(!actualProvider.http_headers || Object.keys(actualProvider.http_headers).length === 0);
    assert(!actualProvider.env_http_headers || Object.keys(actualProvider.env_http_headers).length === 0);
    assert(!config.mcp_servers || Object.keys(config.mcp_servers).length === 0);
    for (const name of disabled) assert.equal(config.features[name],false);
    for (const name of enabled) assert.equal(config.features[name],true);
    assert.equal(config.features.skip_host_skill_discovery,true);
    const loaded = loadedRules(effective.layers);
    const session = effective.layers.filter(layer => layer.name.type === 'sessionFlags');
    assert.equal(session.length,1);
    // Native config/read's typed ToolsV2 omits these fields. Inspect the actual
    // highest-precedence native layer/origins; offered catalog remains unproved.
    for (const tool of ['experimental_request_user_input','update_plan'])
      assert.equal(session[0].config.tools[tool].enabled,false);
    const origins = {};
    for (const key of originKeys) {assert(plain(effective.origins[key]));origins[key]=effective.origins[key];}
    assert.deepEqual(origins.approval_policy.name,{type:'project',dotCodexFolder:`${root}/.codex`});
    // Pinned native method accepts Option<()>; omit params, not an object.
    const managed = (await request('configRequirements/read')).requirements;
    assert(plain(managed));
    const managedObservation = {
      allowed_approval_policies:managed.allowedApprovalPolicies,
      allowed_approvals_reviewers:managed.allowedApprovalsReviewers,
      allowed_web_search_modes:managed.allowedWebSearchModes,
      default_permissions:managed.defaultPermissions,
      allowed_permission_profiles:managed.allowedPermissionProfiles,
      allow_login_shell:managed.allowLoginShell,
      check_for_update_on_startup:managed.checkForUpdateOnStartup,
      feature_requirements:managed.featureRequirements};
    assert.deepEqual(managedObservation,{allowed_approval_policies:['untrusted'],allowed_approvals_reviewers:['user'],
      allowed_web_search_modes:['disabled'],default_permissions:'hf_candidate',allowed_permission_profiles:{hf_candidate:true},
      allow_login_shell:false,check_for_update_on_startup:false,feature_requirements:managedFeatures});
    const listing = await request('skills/list',{cwds:[root],forceReload:true});
    const bucket = listing.data.find(item => item.cwd === root);
    assert(bucket && Array.isArray(bucket.skills) && (!bucket.errors || bucket.errors.length === 0));
    const skills = bucket.skills.filter(skill => skill.enabled).map(skill => skill.path).sort();
    assert.deepEqual(skills,expected.skill_paths);
    function checkThread(thread) {
      assert.equal(thread.model,expected.model);
      assert.equal(thread.modelProvider,'harnessforge_local');
      assert.equal(thread.cwd,root);
      assert.deepEqual(thread.runtimeWorkspaceRoots,[root]);
      assert.equal(thread.approvalPolicy,'untrusted');
      assert.equal(thread.approvalsReviewer,'user');
      assert.deepEqual(thread.activePermissionProfile,{id:'hf_candidate',extends:null});
      // Legacy projection is a strict observed gate, not denied-read proof.
      assert.deepEqual(thread.sandbox,{type:'workspaceWrite',writableRoots:[root],networkAccess:false,
        excludeTmpdirEnvVar:true,excludeSlashTmp:true});
      assert.deepEqual(thread.instructionSources,[`${root}/AGENTS.md`]);
      assert(plain(thread.thread) && typeof thread.thread.id === 'string');
      assert(Array.isArray(thread.thread.environments) && thread.thread.environments.length === 1);
      const environment = thread.thread.environments[0];
      assert.deepEqual(Object.keys(environment).sort(),['environmentId','cwd','runtimeWorkspaceRoots'].sort());
      assert(typeof environment.environmentId === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(environment.environmentId));
      assert.equal(environment.cwd,root);
      assert.deepEqual(environment.runtimeWorkspaceRoots,[root]);
      return environment;
    }
    const threadParams = {model:expected.model,modelProvider:'harnessforge_local',cwd:root,
      runtimeWorkspaceRoots:[root],approvalsReviewer:'user',permissions:'hf_candidate',ephemeral:true};
    const bootstrap = await request('thread/start',threadParams);
    checkThread(bootstrap);
    observedBootstrapPolicy = {approval_policy_override:null,approval_policy:bootstrap.approvalPolicy,
      approvals_reviewer:bootstrap.approvalsReviewer,active_permission_profile:bootstrap.activePermissionProfile,
      model:bootstrap.model,model_provider:bootstrap.modelProvider,cwd:bootstrap.cwd};
    const thread = await request('thread/start',{...threadParams,approvalPolicy:'untrusted'});
    const environment = checkThread(thread);
    assert.notEqual(thread.thread.id,bootstrap.thread.id);
    const info = await request('environment/info',{environmentId:environment.environmentId});
    const status = await request('environment/status',{environmentId:environment.environmentId});
    assert.deepEqual(info,{shell:{name:'bash',path:'/bin/bash'},cwd:'file:///candidate'});
    assert.deepEqual(status,{status:'ready'});
    assert(!protocolError && stderr === '');
    assert(!notifications.some(item => /warning|error|approval|elicitation|turn\/started/i.test(item.method || '')));
    const observation = {version:3,cli_version:'0.156.0',protocol:'ollama-native-responses-v1',
      model:thread.model,model_provider:thread.modelProvider,raw_config_approval_policy:config.approval_policy,
      approval_policy:thread.approvalPolicy,bootstrap_policy:observedBootstrapPolicy,
      approvals_reviewer:thread.approvalsReviewer,default_permissions:config.default_permissions,
      active_permission_profile:thread.activePermissionProfile,sandbox_policy:thread.sandbox,
      network_access:thread.sandbox.networkAccess,web_search:config.web_search,provider,
      disabled_features:disabled,enabled_features:enabled,skip_host_skill_discovery:true,bundled_skills_enabled:false,
      origins,shell_environment:config.shell_environment_policy,
      tools:{experimental_request_user_input:session[0].config.tools.experimental_request_user_input.enabled,
        update_plan:session[0].config.tools.update_plan.enabled},managed_requirements:managedObservation,
      rule_roots:rules,loaded_rule_roots:loaded,
      initialize:{user_agent:initialize.userAgent,codex_home:initialize.codexHome,
        platform_family:initialize.platformFamily,platform_os:initialize.platformOs},
      environment:{environment_id:environment.environmentId,cwd:environment.cwd,
        runtime_workspace_roots:environment.runtimeWorkspaceRoots,info,status},
      instruction_sources:thread.instructionSources,skill_paths:skills,
      overlay_sha256:expected.overlay_sha256,guidance_sha256:expected.guidance_sha256,
      project_config_sha256:expected.project_config_sha256,requirements_sha256:expected.requirements_sha256,
      rule_directory_uids:expected.rule_directory_uids,
      warnings:[],turns_started:0,agent_invocation_verified:false,command_bridge_qualified:false};
    process.stdout.write(JSON.stringify(observation) + '\n');
  } finally {
    for (const item of pending.values()) clearTimeout(item.timer);
    const stop = signal => {try {process.kill(-child.pid,signal);} catch(error) {if(error.code !== 'ESRCH') throw error;}};
    stop('SIGTERM');
    await new Promise(resolve => {
      if(child.exitCode !== null) return resolve();
      const timer=setTimeout(() => {stop('SIGKILL');resolve();},2000);
      child.once('exit',() => {clearTimeout(timer);resolve();});
    });
  }
}
main().catch(() => {
  process.stderr.write(JSON.stringify({version:3,status:'rejected',phase,
    reason:'codex_preflight_rejected',native_error_code:nativeErrorCode,
    raw_config_approval_policy:observedRawPolicy,bootstrap_policy:observedBootstrapPolicy}) + '\n');
  process.exitCode=1;
});
