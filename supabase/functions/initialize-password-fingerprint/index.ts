import { withSupabase } from 'npm:@supabase/server@^1'

// =========================================================
// CREATE PASSWORD FINGERPRINT
// =========================================================

async function createPasswordFingerprint(
  password: string,
  secret: string,
): Promise<string> {
  const normalizedPassword =
    password.trim().toLowerCase()

  const encoder = new TextEncoder()

  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    {
      name: 'HMAC',
      hash: 'SHA-256',
    },
    false,
    ['sign'],
  )

  const signature =
    await crypto.subtle.sign(
      'HMAC',
      key,
      encoder.encode(normalizedPassword),
    )

  return Array.from(
    new Uint8Array(signature),
  )
    .map(
      (byte) =>
        byte
          .toString(16)
          .padStart(2, '0'),
    )
    .join('')
}

// =========================================================
// FUNCTION
// =========================================================

export default {
  fetch: withSupabase(
    {
      auth: 'user',
    },

    async (req, ctx) => {
      try {
        // ===============================================
        // AUTHENTICATED USER
        // ===============================================

        const {
          data: userData,
          error: userError,
        } =
          await ctx.supabase.auth
            .getUser()

        if (
          userError ||
          userData.user == null
        ) {
          return Response.json(
            {
              success: false,
              error:
                'Authentication required.',
            },
            {
              status: 401,
            },
          )
        }

        const user =
          userData.user

        // ===============================================
        // GET PASSWORD
        // ===============================================

        const body =
          await req.json()

        const password =
          body.password

        if (
          typeof password !==
            'string' ||
          password.length === 0
        ) {
          return Response.json(
            {
              success: false,
              error:
                'Password is required.',
            },
            {
              status: 400,
            },
          )
        }

        // ===============================================
        // DO NOT OVERWRITE EXISTING FINGERPRINT
        // ===============================================

        const {
          data: existingRecord,
          error: existingError,
        } =
          await ctx.supabaseAdmin
            .from(
              'password_security',
            )
            .select(
              'user_id',
            )
            .eq(
              'user_id',
              user.id,
            )
            .maybeSingle()

        if (existingError) {
          console.error(
            'CHECK FINGERPRINT ERROR:',
            existingError,
          )

          return Response.json(
            {
              success: false,
              error:
                'Unable to initialize password security.',
            },
            {
              status: 500,
            },
          )
        }

        // Already initialized.
        if (existingRecord != null) {
          return Response.json(
            {
              success: true,
              alreadyInitialized: true,
            },
            {
              status: 200,
            },
          )
        }

        // ===============================================
        // SECRET
        // ===============================================

        const fingerprintSecret =
          Deno.env.get(
            'PASSWORD_FINGERPRINT_SECRET',
          )

        if (!fingerprintSecret) {
          return Response.json(
            {
              success: false,
              error:
                'Server configuration error.',
            },
            {
              status: 500,
            },
          )
        }

        // ===============================================
        // CREATE FINGERPRINT
        // ===============================================

        const fingerprint =
          await createPasswordFingerprint(
            password,
            fingerprintSecret,
          )

        // ===============================================
        // SAVE
        // ===============================================

        const {
          error: insertError,
        } =
          await ctx.supabaseAdmin
            .from(
              'password_security',
            )
            .insert({
              user_id:
                user.id,

              password_fingerprint:
                fingerprint,
            })

        if (insertError) {
          console.error(
            'SAVE FINGERPRINT ERROR:',
            insertError,
          )

          return Response.json(
            {
              success: false,
              error:
                'Unable to initialize password security.',
            },
            {
              status: 500,
            },
          )
        }

        return Response.json(
          {
            success: true,
          },
          {
            status: 200,
          },
        )
      } catch (error) {
        console.error(
          'INITIALIZE PASSWORD FINGERPRINT ERROR:',
          error,
        )

        return Response.json(
          {
            success: false,
            error:
              error instanceof Error
                ? error.message
                : 'Unable to initialize password security.',
          },
          {
            status: 500,
          },
        )
      }
    },
  ),
}