import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

test('csv', async () => {
  const { data, error } = await client().from('users').select('username').order('username').csv()
  assert.equal(error, null); assert.equal(data, 'username\nawailas\ndragarcia\njsonuser\nkiwicopple\nsupabot')
})
test('stripNulls', async () => {
  const { data, error } = await client().from('users').select('username,data').eq('username', 'supabot').stripNulls()
  assert.equal(error, null); assert.deepEqual(data, [{ username: 'supabot' }])
})
// Plan nodes differ deliberately; see PgRest.SQL.Explain, Differences from PostgREST.
// Assert the documented plan shape, without comparing either engine's SQL or costs.
test('explain JSON shape only', async () => {
  const { data, error } = await client().from('users').select().explain({ format: 'json' })
  assert.equal(error, null); assert.equal(typeof data[0].Plan['Node Type'], 'string')
})
test('explain text shape only', async () => {
  const { data, error } = await client().from('users').select().explain()
  assert.equal(error, null); assert.equal(typeof data, 'string'); assert.match(data, /cost=/)
})
