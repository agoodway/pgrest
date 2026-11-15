import test from 'node:test'
import assert from 'node:assert/strict'
import { client, sign } from './helpers.mjs'

for (const limit of [1, 5]) {
  for (const operation of ['update', 'delete', 'rpc']) test(`${operation} maxAffected ${limit}`, async () => {
    let query
    if (operation === 'update') query = client().from('users').update({ status: 'OFFLINE' }).neq('username', 'absent')
    if (operation === 'delete') query = client().from('messages').delete().gt('id', 0)
    if (operation === 'rpc') query = client().rpc('set_users_offline', { name_param: '%' })
    const { error, data } = await query.select().maxAffected(limit).rollback()
    if (limit === 1) assert.equal(error.code, 'PGRST124')
    else { assert.equal(error, null); assert.equal(data.length, operation === 'delete' ? 4 : 5) }
  })
}
