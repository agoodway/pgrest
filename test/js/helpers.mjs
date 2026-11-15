import { PostgrestClient } from '@supabase/postgrest-js'
import { createHmac } from 'node:crypto'

export function client({ schema, token } = {}) {
  return new PostgrestClient(process.env.BASE_URL, {
    schema,
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  })
}

// Same test-only secret as PgRest.Compat.JWT and the existing compose fixture.
export function sign(claims) {
  const segment = value => Buffer.from(JSON.stringify(value)).toString('base64url')
  const input = `${segment({ alg: 'HS256', typ: 'JWT' })}.${segment(claims)}`
  return `${input}.${createHmac('sha256', 'reallyreallyreallyreallyverysafe').update(input).digest('base64url')}`
}
