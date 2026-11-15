import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

test('select all users', async () => {
  const { data, error, status } = await client().from('users').select().order('username')
  assert.equal(error, null); assert.equal(status, 200); assert.equal(data.length, 5)
})
test('single() with many rows is PGRST116', async () => {
  const { error, status } = await client().from('users').select().single()
  assert.equal(status, 406); assert.equal(error.code, 'PGRST116')
})
test('projection, alias and JSON path', async () => {
  const { data, error } = await client().from('users').select('name:username,nested:data->foo->bar->>nested').eq('username', 'jsonuser').single()
  assert.equal(error, null); assert.deepEqual(data, { name: 'jsonuser', nested: 'value' })
})
test('single one row', async () => {
  const { data, error } = await client().from('users').select('username').eq('username', 'supabot').single()
  assert.equal(error, null); assert.deepEqual(data, { username: 'supabot' })
})
for (const [name, query, expected] of [
  ['zero', q => q.eq('username', 'absent'), null],
  ['one', q => q.eq('username', 'supabot'), { username: 'supabot' }],
]) test(`maybeSingle ${name}`, async () => {
  const { data, error } = await query(client().from('users').select('username')).maybeSingle()
  assert.equal(error, null); assert.deepEqual(data, expected)
})
test('maybeSingle many rows fails', async () => {
  const { error, status } = await client().from('users').select().maybeSingle()
  assert.equal(status, 406); assert.equal(error.code, 'PGRST116')
})
for (const count of ['exact', 'planned', 'estimated']) test(`select count ${count}`, async () => {
  const result = await client().from('users').select('*', { count }).order('username')
  assert.equal(result.error, null); assert.equal(result.data.length, 5); assert.ok(result.count >= 0)
  if (count === 'exact') assert.equal(result.count, 5)
})
test('head exact count', async () => {
  const result = await client().from('users').select('*', { head: true, count: 'exact' })
  assert.equal(result.error, null); assert.equal(result.data, null); assert.equal(result.count, 5)
})
test('throwOnError rejects a server error', async () => {
  await assert.rejects(async () => await client().from('users').select('absent').throwOnError(), { code: '42703' })
})
