import { withSupabase } from 'npm:@supabase/server'

export default {
  fetch: withSupabase(
    { auth: 'user' },

    async (_req, ctx) => {
      try {
        // Get the currently logged-in user
        const {
          data: { user },
          error: userError,
        } = await ctx.supabase.auth.getUser()

        if (userError || !user) {
          return Response.json(
            { error: 'Unauthorized' },
            { status: 401 },
          )
        }

        // Delete the currently authenticated user
        const { error: deleteError } =
          await ctx.supabaseAdmin.auth.admin.deleteUser(
            user.id,
          )

        if (deleteError) {
          return Response.json(
            { error: deleteError.message },
            { status: 500 },
          )
        }

        return Response.json({
          success: true,
          message: 'Account deleted successfully',
        })
      } catch (error) {
        return Response.json(
          {
            error:
              error instanceof Error
                ? error.message
                : 'Unable to delete account',
          },
          { status: 500 },
        )
      }
    },
  ),
}