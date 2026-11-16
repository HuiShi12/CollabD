import { withSupabase } from 'npm:@supabase/server@^1'

// =========================================================
// CREATE PASSWORD FINGERPRINT
// =========================================================

async function createPasswordFingerprint(
  password: string,
  secret: string,
): Promise<string> {
  // Your similarity rule:
  //
  // Abc1234@
  // aBc1234@
  // ABC1234@
  //
  // are treated as equivalent.
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
      encoder.encode(
        normalizedPassword,
      ),
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
// EDGE FUNCTION
// =========================================================

export default {
  fetch: withSupabase(
    {
      auth: 'user',
    },

    async (req, ctx) => {
      try {
        // =================================================
        // GET AUTHENTICATED USER
        // =================================================

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
                'Invalid or expired password recovery session.',
            },
            {
              status: 401,
            },
          )
        }

        const user =
          userData.user

        // =================================================
        // GET NEW PASSWORD
        // =================================================

        const body =
          await req.json()

        const newPassword =
          body.newPassword

        if (
          typeof newPassword !==
            'string' ||
          newPassword.length === 0
        ) {
          return Response.json(
            {
              success: false,
              error:
                'New password is required.',
            },
            {
              status: 400,
            },
          )
        }

        // =================================================
        // PASSWORD STRENGTH CHECK
        // =================================================

        const strongPassword =
          newPassword.length >= 8 &&
          /[A-Z]/.test(
            newPassword,
          ) &&
          /[a-z]/.test(
            newPassword,
          ) &&
          /[0-9]/.test(
            newPassword,
          ) &&
          /[^A-Za-z0-9]/.test(
            newPassword,
          )

        if (!strongPassword) {
          return Response.json(
            {
              success: false,
              error:
                'Password must contain at least 8 characters, including uppercase, lowercase, number and special character.',
            },
            {
              status: 400,
            },
          )
        }

        // =================================================
        // GET FINGERPRINT SECRET
        // =================================================

        const fingerprintSecret =
          Deno.env.get(
            'PASSWORD_FINGERPRINT_SECRET',
          )

        if (!fingerprintSecret) {
          console.error(
            'PASSWORD_FINGERPRINT_SECRET is missing',
          )

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

        // =================================================
        // CREATE NEW FINGERPRINT
        // =================================================

        const newFingerprint =
          await createPasswordFingerprint(
            newPassword,
            fingerprintSecret,
          )

        // =================================================
        // GET OLD FINGERPRINT
        // =================================================

        const {
          data: securityRecord,
          error: securityError,
        } =
          await ctx.supabaseAdmin
            .from(
              'password_security',
            )
            .select(
              'password_fingerprint',
            )
            .eq(
              'user_id',
              user.id,
            )
            .maybeSingle()

        if (securityError) {
          console.error(
            'PASSWORD SECURITY READ ERROR:',
            securityError,
          )

          return Response.json(
            {
              success: false,
              error:
                'Unable to verify previous password.',
            },
            {
              status: 500,
            },
          )
        }

        // =================================================
        // REJECT SAME / CASE-ONLY PASSWORD
        // =================================================

        if (
          securityRecord != null &&
          securityRecord
              .password_fingerprint ===
            newFingerprint
        ) {
          return Response.json(
            {
              success: false,
              code:
                'PASSWORD_TOO_SIMILAR',
              error:
                'New password is too similar to your previous password.',
            },
            {
              status: 400,
            },
          )
        }

        // =================================================
        // UPDATE PASSWORD IN SUPABASE AUTH
        // =================================================

        const {
          error: passwordUpdateError,
        } =
          await ctx.supabaseAdmin
            .auth.admin
            .updateUserById(
              user.id,
              {
                password:
                  newPassword,
              },
            )

        if (passwordUpdateError) {
          console.error(
            'PASSWORD UPDATE ERROR:',
            passwordUpdateError,
          )

          return Response.json(
            {
              success: false,
              error:
                'Unable to update password.',
            },
            {
              status: 500,
            },
          )
        }

        // =================================================
        // SAVE NEW FINGERPRINT
        // =================================================

        const {
          error: fingerprintSaveError,
        } =
          await ctx.supabaseAdmin
            .from(
              'password_security',
            )
            .upsert(
              {
                user_id:
                  user.id,

                password_fingerprint:
                  newFingerprint,

                updated_at:
                  new Date()
                    .toISOString(),
              },
              {
                onConflict:
                  'user_id',
              },
            )

        if (fingerprintSaveError) {
          console.error(
            'PASSWORD FINGERPRINT SAVE ERROR:',
            fingerprintSaveError,
          )

          return Response.json(
            {
              success: false,
              error:
                'Password was updated, but password security information could not be saved.',
            },
            {
              status: 500,
            },
          )
        }

        // =================================================
        // SUCCESS
        // =================================================

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
          'SECURE PASSWORD UPDATE ERROR:',
          error,
        )

        return Response.json(
          {
            success: false,
            error:
              error instanceof Error
                ? error.message
                : 'Unable to update password.',
          },
          {
            status: 500,
          },
        )
      }
    },
  ),
}