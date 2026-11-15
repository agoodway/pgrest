import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

test('descending order and null placement', async () => {
  const { data, error } = await client().from('user_profiles').select('username').order('username', { ascending: false, nullsFirst: true })
  assert.equal(error, null); assert.deepEqual(data, [{ username: null }, { username: 'supabot' }])
})
test('limit', async () => {
  const { data, error } = await client().from('users').select('username').order('username').limit(2)
  assert.equal(error, null); assert.deepEqual(data, [{ username: 'awailas' }, { username: 'dragarcia' }])
})
test('inclusive range', async () => {
  const { data, error } = await client().from('users').select('username').order('username').range(1, 2)
  assert.equal(error, null); assert.deepEqual(data, [{ username: 'dragarcia' }, { username: 'jsonuser' }])
})
test('empty range past end', async () => {
  const { data, error } = await client().from('users').select().order('username').range(20, 21)
  assert.equal(error, null); assert.deepEqual(data, [])
})
