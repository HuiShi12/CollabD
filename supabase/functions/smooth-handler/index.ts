import { withSupabase } from 'npm:@supabase/server'

function canonicalizeEmail(rawEmail: string): string {
  const email =
    rawEmail.trim().toLowerCase()

  const atIndex =
    email.lastIndexOf('@')

  if (atIndex <= 0) {
    return email
  }

  let localPart =
    email.substring(0, atIndex)

  let domain =
    email.substring(atIndex + 1)

  // Gmail-specific normalization only.
  if (
    domain === 'gmail.com' ||
    domain === 'googlemail.com'
  ) {
    // Gmail ignores + aliases.
    localPart =
      localPart.split('+')[0]

    // Gmail ignores dots.
    localPart =
      localPart.replace(/\./g, '')

    // Treat googlemail.com as gmail.com.
    domain = 'gmail.com'
  }

  return `${localPart}@${domain}`
}

export default {
  fetch: withSupabase(
    { auth: 'publishable' },

    async (req, ctx) => {
      try {
        const body =
          await req.json()

        const email =
          body.email
            ?.trim()
            .toLowerCase()

        if (!email) {
          return Response.json(
            {
              exists: false,
              error: 'Email is required.',
            },
            {
              status: 400,
            },
          )
        }

        const targetEmail =
          canonicalizeEmail(email)

        const perPage = 1000
        let page = 1

        while (true) {
          const {
            data,
            error,
          } =
            await ctx.supabaseAdmin.auth.admin.listUsers({
              page,
              perPage,
            })

          if (error) {
            console.error(
              'LIST USERS ERROR:',
              error,
            )

            return Response.json(
              {
                exists: false,
                error: error.message,
              },
              {
                status: 500,
              },
            )
          }

          const user =
            data.users.find(
              (user) => {
                if (!user.email) {
                  return false
                }

                return (
                  canonicalizeEmail(
                    user.email,
                  ) === targetEmail
                )
              },
            )

          if (user) {
            const storedEmail =
              user.email
                ?.trim()
                .toLowerCase() ?? ''

            const exactMatch =
              storedEmail === email

            const confirmed =
              user.email_confirmed_at !=
              null

            console.log(
              `EMAIL MATCH FOUND: ${email}`,
            )

            console.log(
              `CANONICAL EMAIL: ${targetEmail}`,
            )

            console.log(
              `EXACT MATCH: ${exactMatch}`,
            )

            console.log(
              `CONFIRMED: ${confirmed}`,
            )

            /*
             * Important:
             *
             * Confirmed account:
             * Always block registration.
             *
             * Unconfirmed + same exact email:
             * Allow the current behaviour so
             * signup can be retried / OTP resent.
             *
             * Unconfirmed + Gmail alias:
             * Block it so a second Auth user
             * cannot be created.
             */
            const exists =
              confirmed ||
              !exactMatch

            return Response.json({
              exists,
              confirmed,
              pending:
                !confirmed,
              exactMatch,
            })
          }

          // No more pages.
          if (
            data.users.length <
            perPage
          ) {
            break
          }

          page++
        }

        console.log(
          `EMAIL NOT FOUND: ${email}`,
        )

        return Response.json({
          exists: false,
          confirmed: false,
          pending: false,
          exactMatch: false,
        })
      } catch (error) {
        console.error(
          'CHECK EMAIL ERROR:',
          error,
        )

        return Response.json(
          {
            exists: false,
            error:
              error instanceof Error
                ? error.message
                : 'Unable to check email.',
          },
          {
            status: 500,
          },
        )
      }
    },
  ),
}