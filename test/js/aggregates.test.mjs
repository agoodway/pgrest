import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

test('count and grouped counts', async () => {
  const total = await client().from('users').select('count()')
  assert.equal(total.error, null); assert.deepEqual(total.data, [{ count: 5 }])
  const grouped = await client().from('users').select('status,count()').order('status')
  assert.equal(grouped.error, null); assert.deepEqual(grouped.data, [{ status: 'ONLINE', count: 4 }, { status: 'OFFLINE', count: 1 }])
})
test('sum avg min max with aliases and casts', async () => {
  const { data, error } = await client().from('messages').select('total:id.sum(),mean:id.avg(),least:id.min(),most:id.max(),cast:id.sum()::text')
  assert.equal(error, null); assert.deepEqual(data, [{ total: 10, mean: 2.5, least: 1, most: 4, cast: '10' }])
})
test('embedded aggregate', async () => {
  const { data, error } = await client().from('channels').select('id,messages(count())').order('id')
  assert.equal(error, null); assert.deepEqual(data, [{ id: 1, messages: [{ count: 1 }] }, { id: 2, messages: [{ count: 1 }] }, { id: 3, messages: [{ count: 2 }] }])
})
