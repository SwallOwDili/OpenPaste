const phrase = 'I have read and agree to the OpenPaste CLA v1.0.';
const branch = 'cla-signatures';
const signaturePath = 'cla/v1.json';
const exempt = new Set(['dependabot[bot]', 'renovate[bot]']);
function hasSigned(records, login) {
  return exempt.has(login) || records.some(r => r.login === login && r.version === '1.0' && r.comment_url);
}
async function load(github, repo) {
  try {
    const {data} = await github.rest.repos.getContent({...repo, path: signaturePath, ref: branch});
    return {records: JSON.parse(Buffer.from(data.content, 'base64').toString()), sha: data.sha};
  } catch (e) { if (e.status !== 404) throw e; return {records: [], sha: undefined}; }
}
async function save(github, repo, records, sha) {
  try { await github.rest.git.getRef({...repo, ref: `heads/${branch}`}); }
  catch (e) {
    if (e.status !== 404) throw e;
    const {data: tree} = await github.rest.git.createTree({...repo, tree: [{path: '.gitkeep', mode: '100644', type: 'blob', content: ''}]});
    const {data: commit} = await github.rest.git.createCommit({...repo, message: 'Initialize CLA signature records', tree: tree.sha, parents: []});
    await github.rest.git.createRef({...repo, ref: `refs/heads/${branch}`, sha: commit.sha});
  }
  await github.rest.repos.createOrUpdateFileContents({...repo, path: signaturePath, branch,
    message: 'Record OpenPaste CLA v1.0 acceptance', sha,
    content: Buffer.from(JSON.stringify(records, null, 2) + '\n').toString('base64')});
}
async function check({github, context, core, number, signing = false}) {
  const repo = context.repo;
  const {data: pr} = await github.rest.pulls.get({...repo, pull_number: number});
  if (pr.state !== 'open') throw new Error('CLA checks apply to open pull requests only');
  const commits = await github.paginate(github.rest.pulls.listCommits, {...repo, pull_number: number, per_page: 100});
  if (commits.length < pr.commits) throw new Error('Cannot verify all PR contributors; maintainer review required');
  const people = new Set([pr.user.login]);
  for (const commit of commits) {
    if (!commit.author) throw new Error('A commit author has no linked GitHub account; link the commit email before signing');
    people.add(commit.author.login);
  }
  const state = await load(github, repo);
  if (signing) {
    const comment = context.payload.comment;
    if (comment.body.trim() === phrase && comment.user.type === 'User' && people.has(comment.user.login)) {
      if (!hasSigned(state.records, comment.user.login)) {
        state.records.push({login: comment.user.login, user_id: comment.user.id, version: '1.0',
          comment_url: comment.html_url, accepted_at: comment.created_at, pull_request: number});
        await save(github, repo, state.records, state.sha);
      }
    }
  }
  const missing = [...people].filter(login => !hasSigned(state.records, login));
  await github.rest.repos.createCommitStatus({...repo, sha: pr.head.sha, context: 'CLA',
    state: missing.length ? 'failure' : 'success',
    description: missing.length ? 'Contributor CLA acceptance required' : 'All contributors accepted CLA v1.0',
    target_url: pr.html_url});
  const marker = '<!-- openpaste-cla-v1 -->';
  const comments = await github.paginate(github.rest.issues.listComments, {...repo, issue_number: number, per_page: 100});
  const previous = comments.find(c => c.user.type === 'Bot' && c.body.includes(marker));
  const body = `${marker}\n${missing.length ? `CLA 签署待完成：${missing.map(n => '@' + n).join(', ')}。\n请阅读 [CLA v1.0](https://github.com/${repo.owner}/${repo.repo}/blob/main/CLA.md)（[中文](https://github.com/${repo.owner}/${repo.repo}/blob/main/CLA.zh-CN.md)），并使用自己的账号回复：\n\n> ${phrase}` : '所有贡献者已签署 CLA v1.0。✅'}`;
  if (previous) await github.rest.issues.updateComment({...repo, comment_id: previous.id, body});
  else await github.rest.issues.createComment({...repo, issue_number: number, body});
  if (missing.length) throw new Error('CLA signature required');
  return pr;
}
async function hasAcceptedStatus(github, repo, sha) {
  const statuses = await github.paginate(github.rest.repos.listCommitStatusesForRef, {...repo, ref: sha, per_page: 100});
  const latest = statuses.find(status => status.context === 'CLA');
  return latest?.state === 'success' && latest.creator?.login === 'github-actions[bot]';
}
module.exports = {check, hasSigned, phrase, hasAcceptedStatus};
