import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

test('insert representation with count and rollback', async () => {
  const { data, error, status, count } = await client().from('messages').insert({ message: 'JS insert', username: 'supabot', channel_id: 1 }, { count: 'exact' }).select('id,message,users(username)').rollback()
  assert.equal(error, null); assert.equal(status, 201); assert.equal(count, 1)
  assert.equal(data[0].message, 'JS insert'); assert.deepEqual(data[0].users, { username: 'supabot' }); assert.ok(data[0].id > 4)
  const check = await client().from('messages').select('id').eq('message', 'JS insert')
  assert.equal(check.error, null); assert.deepEqual(check.data, [])
})
test('bulk insert', async () => {
  const { data, error, count } = await client().from('users').insert([{ username: 'js_one' }, { username: 'js_two' }], { count: 'exact' }).select('username,status').order('username').rollback()
  assert.equal(error, null); assert.equal(count, 2); assert.deepEqual(data, [{ username: 'js_one', status: 'ONLINE' }, { username: 'js_two', status: 'ONLINE' }])
})
test('minimal insert', async () => {
  const { data, error, status } = await client().from('users').insert({ username: 'js_minimal' }).rollback()
  assert.equal(error, null); assert.equal(status, 201); assert.equal(data, null)
})
for (const ignoreDuplicates of [false, true]) test(`upsert ignoreDuplicates=${ignoreDuplicates}`, async () => {
  const { data, error, count } = await client().from('users').upsert({ username: 'supabot', status: 'OFFLINE' }, { onConflict: 'username', ignoreDuplicates, count: 'exact' }).select('username,status').rollback()
  assert.equal(error, null); assert.equal(count, ignoreDuplicates ? 0 : 1)
  assert.deepEqual(data, ignoreDuplicates ? [] : [{ username: 'supabot', status: 'OFFLINE' }])
})
test('update count representation and rollback', async () => {
  const { data, error, count } = await client().from('users').update({ status: 'OFFLINE' }, { count: 'exact' }).eq('username', 'supabot').select('username,status').rollback()
  assert.equal(error, null); assert.equal(count, 1); assert.deepEqual(data, [{ username: 'supabot', status: 'OFFLINE' }])
  const check = await client().from('users').select('status').eq('username', 'supabot').single()
  assert.equal(check.error, null); assert.equal(check.data.status, 'ONLINE')
})
test('delete count representation and rollback', async () => {
  const { data, error, count } = await client().from('messages').delete({ count: 'exact' }).eq('id', 1).select('id').rollback()
  assert.equal(error, null); assert.equal(count, 1); assert.deepEqual(data, [{ id: 1 }])
})
