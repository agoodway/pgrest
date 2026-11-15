import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

test('many to one', async () => {
  const { data, error } = await client().from('messages').select('id,users(username)').eq('id', 1).single()
  assert.equal(error, null); assert.deepEqual(data, { id: 1, users: { username: 'supabot' } })
})
test('embedded order, limit and range', async () => {
  const base = () => client().from('users').select('username,messages(id)').eq('username', 'supabot').order('id', { referencedTable: 'messages', ascending: false })
  const limited = await base().limit(2, { referencedTable: 'messages' }).single()
  assert.equal(limited.error, null); assert.deepEqual(limited.data.messages, [{ id: 4 }, { id: 3 }])
  const ranged = await base().range(1, 2, { referencedTable: 'messages' }).single()
  assert.equal(ranged.error, null); assert.deepEqual(ranged.data.messages, [{ id: 3 }, { id: 2 }])
})
test('inner embed filters parent', async () => {
  const { data, error } = await client().from('users').select('username,messages!inner(id)').eq('messages.channel_id', 1).order('username').order('id', { referencedTable: 'messages' })
  assert.equal(error, null); assert.deepEqual(data, [{ username: 'supabot', messages: [{ id: 1 }] }])
})
test('many to many', async () => {
  const { data, error } = await client().from('products').select('id,categories(id)').eq('id', 1).order('id', { referencedTable: 'categories' }).single()
  assert.equal(error, null); assert.deepEqual(data.categories, [{ id: 1 }, { id: 2 }])
})
test('spread many to one', async () => {
  const { data, error } = await client().from('messages').select('id,...users(username,status)').eq('id', 1).single()
  assert.equal(error, null); assert.deepEqual(data, { id: 1, username: 'supabot', status: 'ONLINE' })
})
test('nested embeds and aliases', async () => {
  const { data, error } = await client().from('messages').select('id,channel:channels(slug,channel_details(details))').eq('id', 1).single()
  assert.equal(error, null); assert.deepEqual(data, { id: 1, channel: { slug: 'public', channel_details: { details: 'Details for public channel' } } })
})
