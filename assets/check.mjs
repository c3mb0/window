import { chromium, firefox } from '@playwright/test';
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
  browser=await (process.env.WINDOW_BROWSER === 'firefox' ? firefox : chromium).launch();
  const context=await browser.newContext({viewport:{width:1100,height:700}});
  const page=await context.newPage();
  if (process.env.WINDOW_CLIPBOARD_ONLY === '1') {
    await page.addInitScript(() => {
      window.clipboardWrites = [];
      window.clipboardReads = 0;
      Object.defineProperty(navigator, 'clipboard', {value: {
        writeText: async text => window.clipboardWrites.push(text),
        readText: async () => {window.clipboardReads++; return "printf 'PASTE_%s\\n' OK";}
      }});
    });
  }
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
  assert.equal(new URL(page.url()).hash, '');
  await page.reload();await waitText('WINDOW>');
  assert.equal(await page.getByRole('tab').count(),1);
  assert.ok(!await page.getByRole('tab').innerText().then(t=>t.includes('Missing startup token')));
  if (process.env.WINDOW_FONT_ONLY === '1') {
    const fontFaces = await page.evaluate(() => Array.from(document.fonts, font => ({family: font.family, status: font.status})));
    assert.ok(fontFaces.some(font => font.family.replaceAll('"', '') === 'Window Symbols' && font.status === 'loaded'), JSON.stringify(fontFaces));
    await type("printf 'BRANCH \\ue0a0 main\\n'");await waitText('BRANCH \ue0a0 main');
    await page.screenshot({path:`test-results/font-${process.env.WINDOW_BROWSER || 'chromium'}.png`});
    assert.deepEqual(errors, []);
    console.log('PASS: local symbol font loaded and Git branch prompt rendered');
  } else if (process.env.WINDOW_KEYS_ONLY === '1') {
    // Observe actual PTY bytes, including duplicate keypress/keyup delivery.
    await type("stty raw -echo; printf 'KEY_%s\\n' READY; dd bs=1 count=8 2>/dev/null | od -An -tx1; stty sane");
    await waitText('KEY_READY');
    await page.keyboard.press('Shift+Enter');
    await page.keyboard.press('Enter');
    await page.waitForFunction(() =>
      /1b\s+5b\s+31\s+33\s+3b\s+32\s+75\s+0d/.test(
        document.querySelector('section:not([hidden]) .xterm-screen')?.textContent || ''));
    await type("printf 'AFTER_%s\\n' KEYS");await waitText('AFTER_KEYS');
    assert.deepEqual(errors, []);
    console.log('PASS: Shift+Enter sends CSI-u once, plain Enter sends CR, shell remains usable');
  } else if (process.env.WINDOW_CLIPBOARD_ONLY === '1') {
    await type("printf 'COPY_%s\\n' TARGET");await waitText('COPY_TARGET');
    await page.getByText('COPY_TARGET',{exact:true}).dblclick();
    await page.keyboard.press('Control+Shift+c');
    assert.deepEqual(await page.evaluate(()=>window.clipboardWrites), ['COPY_TARGET']);
    await page.locator('section:not([hidden]) textarea').focus();
    await page.keyboard.press('Control+Shift+v');await page.keyboard.press('Enter');await waitText('PASTE_OK');
    assert.equal(await page.evaluate(()=>window.clipboardReads), 1);
    await type('sh -c "printf \'JOB_%s\\n\' READY; exec sleep 30"');await waitText('JOB_READY');
    await page.getByText('COPY_TARGET',{exact:true}).dblclick();
    await page.keyboard.press('Control+c');
    await type("printf 'INTERRUPT_%s\\n' OK");await waitText('INTERRUPT_OK');
    assert.equal(await page.evaluate(()=>window.clipboardWrites.length), 1);
    assert.deepEqual(errors, []);
    console.log('PASS: Ctrl-Shift-C copies selection, Ctrl-Shift-V pastes once, selected Ctrl-C interrupts the real foreground job');
  } else if (process.env.WINDOW_IDLE_ONLY === '1') {
    const idleMs = Number(process.env.WINDOW_IDLE_MS || 125000);
    await page.getByRole('button',{name:'Open terminal'}).click();await waitText('WINDOW>');
    for (const [name, value] of [['Terminal 1','first'],['Terminal 2','second']]) {
      await page.getByRole('tab',{name,exact:true}).click();
      await type(`WINDOW_IDLE_SENTINEL=${value}`);
    }
    // Leave both shells untouched. One terminal is hidden inside the page.
    // Capture any transient disconnect, even if a later reconnect masks it.
    await page.evaluate(() => {
      window.idleFailures = [];
      new MutationObserver(() => {
        if (/Disconnected|failed|stopped/i.test(document.querySelector('#tabs').textContent))
          window.idleFailures.push(document.querySelector('#tabs').textContent);
      }).observe(document.querySelector('#tabs'), {subtree:true,childList:true,characterData:true});
    });
    console.log(`Waiting ${idleMs / 1000}s with two idle shells`);
    await page.waitForTimeout(idleMs);
    assert.deepEqual(await page.evaluate(() => window.idleFailures), []);
    for (const [name, value] of [['Terminal 1','first'],['Terminal 2','second']]) {
      await page.getByRole('tab',{name,exact:true}).click();
      await type("printf 'IDLE_%s\\n' \"$WINDOW_IDLE_SENTINEL\"");await waitText(`IDLE_${value}`);
    }
    assert.deepEqual(errors,[]);
    console.log('PASS: both original shells accept input after idle; no disconnect observed');
  } else if (process.env.WINDOW_REFRESH_ONLY === '1') {
    console.log('PASS: shell access survives page refresh without a URL token');
  } else {
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
  }
} finally {
  await browser?.close();
  server.kill('SIGTERM');
  await Promise.race([once(server,'exit'),new Promise(r=>setTimeout(r,5000))]);
  rmSync(shellConfig,{recursive:true,force:true});
}
