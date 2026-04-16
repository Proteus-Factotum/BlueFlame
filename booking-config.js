window.BOOKING_CONFIG = {
  supabaseUrl: "https://tdjfdpfqwoijiooovhxr.supabase.co",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRkamZkcGZxd29pamlvb292aHhyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYzNDY1MTMsImV4cCI6MjA5MTkyMjUxM30.OeRaU3D36O6-3TEhdwW-xLwZfGykupFX_ROKPNhmQAU",
  defaultSlug: "robin-hansen",
  localTesting: {
    enableDummySession: true,
    profile: {
      id: "local-profile",
      slug: "robin-hansen",
      display_name: "Robin Hansen",
      notification_email: "robin@example.com"
    },
    automations: [
      { id: "auto-1", start_time: "16:00", weekdays: [1, 2, 4] },
      { id: "auto-2", start_time: "19:30", weekdays: [3, 5] },
      { id: "auto-3", start_time: "14:00", weekdays: [0, 6] }
    ],
    manualOverrides: {
      "2026-04-20": { action: "set", start_time: "16:00" },
      "2026-04-24": { action: "set", start_time: "18:00" },
      "2026-04-26": { action: "clear" }
    },
    heldDates: [
      { id: "held-0", booked_on: "2026-04-13", start_time: "18:30", guest_name: "Sofia", guest_contact: "sofia@example.com" },
      { id: "held-0b", booked_on: "2026-04-15", start_time: "16:00", guest_name: "Nina", guest_contact: "+45 61 11 22 33" },
      { id: "held-1", booked_on: "2026-04-21", start_time: "17:00", guest_name: "Maya", guest_contact: "+45 70 00 00 00" },
      { id: "held-2", booked_on: "2026-04-25", start_time: "15:30", guest_name: "Elena", guest_contact: "elena@example.com" }
    ]
  }
};
