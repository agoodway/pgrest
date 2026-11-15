import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

const cases = [
  ['eq', q => q.eq('username', 'supabot'), ['supabot']],
  ['neq', q => q.neq('status', 'ONLINE'), ['kiwicopple']],
  ['gt', q => q.gt('username', 'kiwicopple'), ['supabot']],
  ['gte', q => q.gte('username', 'kiwicopple'), ['kiwicopple', 'supabot']],
  ['lt', q => q.lt('username', 'dragarcia'), ['awailas']],
  ['lte', q => q.lte('username', 'dragarcia'), ['awailas', 'dragarcia']],
  ['like', q => q.like('username', '%bot'), ['supabot']],
  ['ilike', q => q.ilike('username', '%BOT'), ['supabot']],
  ['likeAllOf', q => q.likeAllOf('username', ['%bot', 's%']), ['supabot']],
  ['likeAnyOf', q => q.likeAnyOf('username', ['%bot', 'a%']), ['awailas', 'supabot']],
  ['ilikeAllOf', q => q.ilikeAllOf('username', ['%BOT', 'S%']), ['supabot']],
  ['ilikeAnyOf', q => q.ilikeAnyOf('username', ['%BOT', 'A%']), ['awailas', 'supabot']],
  ['in', q => q.in('username', ['supabot', 'awailas', 'supabot']), ['awailas', 'supabot']],
  ['is', q => q.is('data', null), ['awailas', 'dragarcia', 'kiwicopple', 'supabot']],
  ['not', q => q.not('status', 'eq', 'ONLINE'), ['kiwicopple']],
  ['or', q => q.or('username.eq.supabot,status.eq.OFFLINE'), ['kiwicopple', 'supabot']],
  ['match', q => q.match({ username: 'supabot', status: 'ONLINE' }), ['supabot']],
  ['filter', q => q.filter('username', 'eq', 'supabot'), ['supabot']],
  ['contains JSON', q => q.contains('data', { foo: { baz: 'string value' } }), ['jsonuser']],
  ['textSearch', q => q.textSearch('catchphrase', 'fat & cat'), ['supabot']],
  ['textSearch plain', q => q.textSearch('catchphrase', 'fat cat', { type: 'plain', config: 'english' }), ['supabot']],
  ['textSearch phrase', q => q.textSearch('catchphrase', 'fat cat', { type: 'phrase' }), []],
  ['textSearch websearch', q => q.textSearch('catchphrase', 'fat cat', { type: 'websearch' }), ['supabot']],
  ['range contains', q => q.contains('age_range', '[1,2)'), ['supabot']],
  ['range containedBy', q => q.containedBy('age_range', '[0,3)'), ['supabot']],
  ['range overlaps', q => q.overlaps('age_range', '[1,2)'), ['supabot']],
  ['rangeGt', q => q.rangeGt('age_range', '[0,1)'), ['awailas', 'dragarcia', 'jsonuser', 'kiwicopple', 'supabot']],
  ['rangeGte', q => q.rangeGte('age_range', '[20,30)'), ['awailas', 'dragarcia', 'jsonuser', 'kiwicopple']],
  ['rangeLt', q => q.rangeLt('age_range', '[3,4)'), ['supabot']],
  ['rangeLte', q => q.rangeLte('age_range', '[1,2)'), ['supabot']],
  ['rangeAdjacent', q => q.rangeAdjacent('age_range', '[2,3)'), ['supabot']],
]
for (const [name, filter, expected] of cases) test(name, async () => {
  const { data, error } = await filter(client().from('users').select('username')).order('username')
  assert.equal(error, null); assert.deepEqual(data.map(row => row.username), expected)
})
for (const [name, query, ids] of [
  ['contains', q => q.contains('array_column', ['test']), [1]],
  ['containedBy', q => q.containedBy('array_column', ['test', 'one']), [1]],
  ['overlaps', q => q.overlaps('array_column', ['test', 'another']), [1, 2]],
]) test(`array ${name}`, async () => {
  const { data, error } = await query(client().from('cornercase').select('id')).order('id')
  assert.equal(error, null); assert.deepEqual(data.map(row => row.id), ids)
})
