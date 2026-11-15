import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

test('sequence probe', async () => {
  const { data, error } = await client().from('messages').insert({ message: 'sequence probe', username: 'supabot', channel_id: 1 }).select('id').single().rollback()
  assert.equal(error, null); assert.ok(Number.isInteger(data.id))
  console.log(`sequence-probe-id=${data.id}`)
})
