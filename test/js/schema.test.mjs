import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

test('schema method selects personal users', async () => {
  const { data, error } = await client().schema('personal').from('users').select('username').order('username')
  assert.equal(error, null); assert.deepEqual(data.map(row => row.username), ['awailas', 'dragarcia', 'kiwicopple', 'leroyjenkins', 'supabot'])
})
test('client schema option', async () => {
  const { data, error } = await client({ schema: 'personal' }).from('users').select('username').eq('username', 'leroyjenkins').single()
  assert.equal(error, null); assert.deepEqual(data, { username: 'leroyjenkins' })
})
test('schema RPC', async () => {
  const { data, error } = await client().schema('personal').rpc('get_status', { name_param: 'leroyjenkins' }, { get: true })
  assert.equal(error, null); assert.equal(data, 'ONLINE')
})
test('schema write uses Content-Profile', async () => {
  const { data, error } = await client().schema('personal').from('users').insert({ username: 'js_personal' }).select('username').rollback()
  assert.equal(error, null); assert.deepEqual(data, [{ username: 'js_personal' }])
})
test('invalid schema', async () => {
  const { error, status } = await client().schema('absent').from('users').select()
  assert.equal(status, 406); assert.equal(error.code, 'PGRST106')
})
