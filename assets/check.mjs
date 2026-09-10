import { chromium } from '@playwright/test';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import assert from 'node:assert/strict';
const shellConfig = mkdtempSync(join(tmpdir(), 'window-browser-'));
writeFileSync(join(shellConfig, '.zshrc'), "PROMPT='WINDOW> '\nunset HISTFILE\n");
const server = spawn('mix', ['run', '--no-halt'], {cwd: new URL('..', import.meta.url), env: {...process.env, WINDOW_SERVER:'1',WINDOW_PORT:'4051',SHELL:'/bin/zsh',ZDOTDIR:shellConfig,MIX_REBAR3:process.env.MIX_REBAR3 || execFileSync('which',['rebar3'],{encoding:'utf8'}).trim()}, stdio:['ignore','pipe','pipe']});
let browser;
try {
  const url = await new Promise((resolve,reject) => {
    const timer=setTimeout(()=>reject(new Error('Server startup timed out')),20000);
    let output='';
    server.stdout.on('data',b=>{output+=b;const m=output.match(/http:\/\/127\.0\.0\.1:4051\/#token=[\w-]+/);if(m){clearTimeout(timer);resolve(m[0]);}});
    server.on('exit',code=>{clearTimeout(timer);reject(new Error(`Server exited ${code}`));});
  });
  browser=await chromium.launch();
  const context=await browser.newContext({viewport:{width:1100,height:700}});
  const page=await context.newPage();
  let observedSize;
  page.on('websocket', ws => ws.on('framereceived', ({payload}) => {
    try {const frame=JSON.parse(String(payload));if(frame[3]==='resized') observedSize=frame[4];} catch {}
  }));
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(url);
  const active=()=>page.locator('section:not([hidden]) .xterm-screen');
  const waitText=async(text)=>{try {await page.waitForFunction(t=>document.querySelector('section:not([hidden]) .xterm-screen')?.textContent.includes(t),text,{timeout:10000});} catch(e) {console.error('SCREEN',await page.locator('body').innerText(),errors);throw e;}};
  const type=async(cmd)=>{await page.locator('section:not([hidden]) textarea').focus();await page.keyboard.type(cmd);await page.keyboard.press('Enter');};
  await waitText('WINDOW>');
  assert.equal(await page.getByRole('tab').count(),1);
  await type("printf 'FIRST_%s\\n' OK");await waitText('FIRST_OK');
  await page.getByRole('button',{name:'Open terminal'}).click();await waitText('WINDOW>');
  await type("printf 'SECOND_%s\\n' OK");await waitText('SECOND_OK');
  await page.getByRole('tab',{name:'Terminal 1',exact:true}).click();await waitText('FIRST_OK');
  // Hidden output continues processing while another independent shell remains usable.
  await type("head -c 200000 /dev/zero | tr '\\000' x; printf '\\nFLOOD_%s\\n' DONE");
  await page.getByRole('tab',{name:'Terminal 2',exact:true}).click();
  await type("printf 'RESPONSIVE_%s\\n' OK");await waitText('RESPONSIVE_OK');
  await page.getByRole('tab',{name:'Terminal 1',exact:true}).click();await waitText('FLOOD_DONE');
  await type("printf '\\342'; sleep 0.1; printf '\\202\\254 \\033[31mRED\\033[0m 漢字\\n'");await waitText('€ RED 漢字');
  const beforeResize=observedSize;
  await page.setViewportSize({width:760,height:500});
  for(let i=0;i<100 && observedSize===beforeResize;i++) await page.waitForTimeout(20);
  assert.notEqual(observedSize,beforeResize);
  await type('stty size');await waitText(`${observedSize.rows} ${observedSize.cols}`);
  await type('seq 1 200 | less');await page.waitForTimeout(300);
  await page.setViewportSize({width:850,height:550});await page.waitForTimeout(200);
  await page.keyboard.press('q');await waitText('WINDOW>');
  await type('sh -c "printf \'JOB_%s\\n\' READY; exec sleep 30"');await waitText('JOB_READY');await page.keyboard.press('Control+z');await waitText('suspended');
  await type('fg');await page.waitForTimeout(200);await page.keyboard.press('Control+c');
  await type("printf 'JOB_%s\\n' OK");await waitText('JOB_OK');
  // Close inactive tab preserves active screen, final close remains empty.
  await page.getByRole('button',{name:'Close Terminal 2',exact:true}).click();await waitText('JOB_OK');
  await page.keyboard.type("printf 'EDIT_%s\\n' OX");
  await page.keyboard.press('Backspace');await page.keyboard.type('K');await page.keyboard.press('Enter');await waitText('EDIT_OK');
  await page.keyboard.press('ArrowUp');await page.keyboard.press('Enter');await page.waitForTimeout(100);
  await page.locator('section:not([hidden]) textarea').evaluate(el=>{
    const data=new DataTransfer();data.setData('text/plain',"printf 'PASTE_%s\\n' OK");
    el.dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));
  });
  await page.keyboard.press('Enter');await waitText('PASTE_OK');
  await page.keyboard.press('Control+d');await page.getByRole('tab').filter({hasText:'Exited'}).waitFor();
  assert.match(await active().innerText(),/JOB_OK/);
  await page.screenshot({path:'test-results/terminal.png'});
  await page.getByRole('button',{name:'Close Terminal 1',exact:true}).click();
  assert.equal(await page.getByRole('tab').count(),0);
  assert.equal(await page.locator('section').count(),0);
  await page.getByRole('button',{name:'Open terminal'}).click();await waitText('WINDOW>');
  await context.setOffline(true);
  await page.getByRole('tab').filter({hasText:'Disconnected'}).waitFor({timeout:35000});
  await context.setOffline(false);await page.waitForTimeout(1000);
  assert.match(await page.getByRole('tab').innerText(),/Disconnected/);
  assert.deepEqual(errors,[]);
  console.log('PASS: real-shell tabs, retained screens, hidden flood, split UTF-8/ANSI, resize, Ctrl-Z/fg/Ctrl-C, exit, final close, disconnect without reconnect');
} finally {
  await browser?.close();
  server.kill('SIGTERM');
  await Promise.race([once(server,'exit'),new Promise(r=>setTimeout(r,5000))]);
  rmSync(shellConfig,{recursive:true,force:true});
}
