import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { test } from 'node:test';
import { randomUUID } from 'node:crypto';

// Execute the actual ArkTS bridge with host filesystem/picker adapters. This
// checks ownership and asynchronous ordering, not HarmonyOS device support.
const template = fs.readFileSync(new URL('app/ohos/entry/src/main/ets/entryability/EntryAbility.ets.template', import.meta.url), 'utf8');
const script = stripTypeScriptTypes(template
  .replace(/^import[\s\S]*?from '[^']+';\s*/gm, '')
  .replace('export default class EntryAbility', 'class EntryAbility') + '\nglobalThis.EntryAbility = EntryAbility;');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'venera-directory-bridge-'));
  assert.ok(path.resolve(root).startsWith(path.resolve(os.tmpdir()) + path.sep));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const state = { uris: [], supported: true, copies: 0, selections: 0, options: null, failRemove: false, copy: null };
  const fileIo = {
    accessSync: fs.existsSync,
    mkdirSync: (value, recursive = false) => fs.mkdirSync(value, { recursive }),
    lstatSync: (value) => fs.lstatSync(value, { bigint: true }),
    listFileSync: (value) => fs.readdirSync(value),
    listFile: (value) => fs.promises.readdir(value),
    unlinkSync: fs.unlinkSync,
    rmdirSync: (value) => {
      if (state.failRemove) throw new Error('synthetic cleanup failure');
      fs.rmdirSync(value);
    },
    copy: async (source, destination) => {
      state.copies++;
      if (state.copy) return state.copy(source, destination);
      const input = fileURLToPath(source);
      await fs.promises.cp(input, path.join(fileURLToPath(destination), path.basename(input)),
        { recursive: true, dereference: false, errorOnExist: true, force: false });
    },
  };
  class FlutterAbility {
    context = { cacheDir: root };
  }
  const context = vm.createContext({
    FlutterAbility, Map, Error, Promise, fileIo,
    canIUse: () => state.supported,
    util: { generateRandomUUID: () => randomUUID() },
    fileUri: {
      getUriFromPath: (value) => pathToFileURL(value).href,
      FileUri: class {
        constructor(uri) { this.name = path.basename(fileURLToPath(uri)); }
      },
    },
    picker: {
      DocumentSelectOptions: class {},
      DocumentSelectMode: { FILE: 0, FOLDER: 1 },
      DocumentViewPicker: class {
        async select(options) {
          state.selections++;
          state.options = options;
          return state.uris;
        }
      },
    },
  });
  vm.runInContext(script, context);
  const ability = new context.EntryAbility();
  const source = path.join(root, 'original', 'Book \u4e2d\u6587');
  fs.mkdirSync(path.join(source, 'Chapter 1'), { recursive: true });
  fs.writeFileSync(path.join(source, 'Chapter 1', '1.png'), 'original page');
  state.uris = [pathToFileURL(source).href];
  async function call(method, args = {}) {
    let output;
    let failure;
    await ability.onMethodCall({ method, argument: (name) => args[name] }, {
      success: (value) => { output = value; },
      error: (code, message) => { failure = Object.assign(new Error(message), { code }); },
      notImplemented: () => { throw new Error('Unexpected method'); },
    });
    if (failure) throw failure;
    return output instanceof Map ? Object.fromEntries(output) : output;
  }
  return { root, source, state, ability, call };
}

test('folder picker cancellation and unavailable capability allocate no receipt', async (t) => {
  const { state, ability, call } = fixture(t);
  state.uris = [];
  assert.equal(await call('selectDirectory'), null);
  assert.equal(ability.directoryReceipts.size, 0);
  state.supported = false;
  await assert.rejects(call('selectDirectory'), { code: 'directory_selection_unavailable' });
  assert.equal(state.selections, 1);
  assert.equal(state.copies, 0);
});

test('copy preserves named chapter structure and separate same-name selections', async (t) => {
  const { source, state, call } = fixture(t);
  const first = await call('selectDirectory');
  const second = await call('selectDirectory');
  assert.notEqual(first.token, second.token);
  assert.equal(state.options.maxSelectNumber, 1);
  assert.equal(state.options.selectMode, 1);
  assert.equal(state.copies, 0);
  await Promise.all([call('prepareDirectory', first), call('prepareDirectory', first), call('prepareDirectory', second)]);
  assert.equal(state.copies, 2);
  for (const receipt of [first, second]) {
    assert.equal(fs.readFileSync(path.join(receipt.path, 'Chapter 1', '1.png'), 'utf8'), 'original page');
    await call('releaseDirectory', receipt);
    assert.equal(fs.existsSync(receipt.path), false);
  }
  assert.equal(fs.readFileSync(path.join(source, 'Chapter 1', '1.png'), 'utf8'), 'original page');
});

test('unconsumed selection can release without copying', async (t) => {
  const { state, call } = fixture(t);
  const receipt = await call('selectDirectory');
  await call('releaseDirectory', receipt);
  assert.equal(state.copies, 0);
});

test('arbitrary paths and tokens never grant recursive deletion', async (t) => {
  const { source, call } = fixture(t);
  const receipt = await call('selectDirectory');
  await assert.rejects(call('releaseDirectory', { ...receipt, path: source }), /Unknown owned/);
  await assert.rejects(call('prepareDirectory', { ...receipt, token: randomUUID() }), /Unknown owned/);
  assert.equal(fs.existsSync(source), true);
  await call('releaseDirectory', receipt);
});

test('release waits for actual copy failure and does not start another copy', async (t) => {
  const { state, call } = fixture(t);
  let fail;
  state.copy = () => new Promise((_, reject) => { fail = reject; });
  const receipt = await call('selectDirectory');
  const copying = call('prepareDirectory', receipt);
  const rejected = assert.rejects(copying, /synthetic copy failure/);
  const releasing = call('releaseDirectory', receipt);
  assert.equal(fs.existsSync(path.dirname(receipt.path)), true);
  fail(new Error('synthetic copy failure'));
  await rejected;
  await releasing;
  assert.equal(state.copies, 1);
  assert.equal(fs.existsSync(path.dirname(receipt.path)), false);
});

test('partial copy failure is not published and cleanup is retryable', async (t) => {
  const { source, state, ability, call } = fixture(t);
  const receipt = await call('selectDirectory');
  state.copy = async () => {
    fs.mkdirSync(receipt.path);
    fs.writeFileSync(path.join(receipt.path, 'partial'), 'partial');
    throw new Error('no space');
  };
  await assert.rejects(call('prepareDirectory', receipt), /no space/);
  await assert.rejects(call('prepareDirectory', receipt), /no space/);
  assert.equal(state.copies, 1);
  state.failRemove = true;
  await assert.rejects(call('releaseDirectory', receipt), /cleanup failure/);
  assert.equal(ability.directoryReceipts.size, 1);
  state.failRemove = false;
  await call('releaseDirectory', receipt);
  assert.equal(ability.directoryReceipts.size, 0);
  assert.equal(fs.existsSync(source), true);
});

test('a replaced receipt root or unknown files block cleanup', async (t) => {
  const { call } = fixture(t);
  const receipt = await call('selectDirectory');
  const root = path.dirname(path.dirname(receipt.path));
  fs.writeFileSync(path.join(root, 'unrelated'), 'keep');
  await assert.rejects(call('releaseDirectory', receipt), /Unknown owned directory contents/);
  fs.unlinkSync(path.join(root, 'unrelated'));
  fs.renameSync(root, root + '-saved');
  fs.mkdirSync(root);
  fs.writeFileSync(path.join(root, 'keep'), 'keep');
  await assert.rejects(call('releaseDirectory', receipt), /ownership changed/);
  assert.equal(fs.readFileSync(path.join(root, 'keep'), 'utf8'), 'keep');
});

test('copied links are rejected and cleanup never follows their target', async (t) => {
  const { source, state, call } = fixture(t);
  const receipt = await call('selectDirectory');
  state.copy = async () => {
    fs.mkdirSync(receipt.path);
    fs.symlinkSync(source, path.join(receipt.path, 'link'), 'junction');
  };
  await assert.rejects(call('prepareDirectory', receipt), /link or special file/);
  await call('releaseDirectory', receipt);
  assert.equal(fs.existsSync(path.join(source, 'Chapter 1', '1.png')), true);
});

test('a changed or flattened copy root cannot be imported', async (t) => {
  const { state, call } = fixture(t);
  const receipt = await call('selectDirectory');
  state.copy = async () => fs.writeFileSync(path.join(path.dirname(receipt.path), '1.png'), 'wrong layout');
  await assert.rejects(call('prepareDirectory', receipt), /preserve its root/);
  await call('releaseDirectory', receipt);
});

test('excessive nesting fails before publishing a directory', async (t) => {
  const { state, call } = fixture(t);
  const receipt = await call('selectDirectory');
  state.copy = async () => fs.mkdirSync(path.join(receipt.path, ...Array(34).fill('a')), { recursive: true });
  await assert.rejects(call('prepareDirectory', receipt), /nesting is too deep/);
  await call('releaseDirectory', receipt);
});

test('folder and file dialogs share the native busy guard', async (t) => {
  const { ability, call } = fixture(t);
  ability.selecting = true;
  await assert.rejects(call('selectDirectory'), /dialog is already active/);
});
