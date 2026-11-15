import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

for (const [sub, expected] of [['alice', ['a1', 'a2']], ['bob', ['b1']]]) test(`RLS reads ${sub}`, async () => {
  const { data, error } = await client({ token: sign({ role: 'authenticated', sub }) }).from('rls_notes').select('body').order('id')
  assert.equal(error, null); assert.deepEqual(data.map(row => row.body), expected)
})
test('anonymous RLS sees no notes', async () => {
  const { data, error } = await client().from('rls_notes').select()
  assert.equal(error, null); assert.deepEqual(data, [])
})
test('RLS insert uses JWT owner and rollback', async () => {
  const { data, error } = await client({ token: sign({ role: 'authenticated', sub: 'alice' }) }).from('rls_notes').insert({ body: 'JS note' }).select('owner,body').rollback()
  assert.equal(error, null); assert.deepEqual(data, [{ owner: 'alice', body: 'JS note' }])
})
test('RLS rejects other owner', async () => {
  const { error, status } = await client({ token: sign({ role: 'authenticated', sub: 'alice' }) }).from('rls_notes').insert({ owner: 'bob', body: 'denied' }).rollback()
  assert.equal(status, 403); assert.equal(error.code, '42501')
})
