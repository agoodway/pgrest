import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

for (const get of [false, true]) test(`scalar RPC get=${get}`, async () => {
  const { data, error } = await client().rpc('get_status', { name_param: 'supabot' }, { get }).rollback()
  assert.equal(error, null); assert.equal(data, 'ONLINE')
})
test('RPC head and count', async () => {
  const { data, error, count } = await client().rpc('get_username_and_status', { name_param: 'supabot' }, { head: true, count: 'exact' })
  assert.equal(error, null); assert.equal(data, null); assert.equal(count, 1)
})
test('table RPC filtering and count', async () => {
  const { data, error, count } = await client().rpc('get_username_and_status', { name_param: 'supabot' }, { count: 'exact' }).eq('status', 'ONLINE').select('username').rollback()
  assert.equal(error, null); assert.equal(count, 1); assert.deepEqual(data, [{ username: 'supabot' }])
})
test('RPC optional and array args', async () => {
  const optional = await client().rpc('function_with_optional_param', {}, { get: true })
  assert.equal(optional.error, null); assert.equal(optional.data, '')
  const array = await client().rpc('sum_scores', { scores: [1, 2, 3], offset_by: 4 }, { get: true })
  assert.equal(array.error, null); assert.equal(array.data, 10)
})
test('volatile RPC rollback', async () => {
  const { data, error } = await client().rpc('offline_user', { name_param: 'supabot' }).rollback()
  assert.equal(error, null); assert.equal(data, 'OFFLINE')
})
test('void RPC', async () => {
  const { data, error, status } = await client().rpc('void_func').rollback()
  assert.equal(error, null); assert.equal(data, null); assert.equal(status, 204)
})
