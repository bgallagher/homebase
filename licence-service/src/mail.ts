// Sends the licence email. Resend (https://resend.com) is used because it needs one HTTPS call; swap this file to change provider.

export interface Mailer {
  /** Resolves once the provider accepted the message; throws otherwise (so the webhook answers 5xx and Paddle retries). */
  sendLicence(to: string, licenceKey: string): Promise<void>;
}

export function licenceEmail(licenceKey: string): { subject: string; text: string } {
  return {
    subject: "Your Rackoon supporter licence",
    text: [
      "Thank you for feeding the Rackoon!",
      "",
      "Your licence key is below. In Rackoon choose Help > Enter Licence…, paste the whole key and press Activate.",
      "Everything in the app works the same with or without it; the key just marks you as a supporter.",
      "",
      licenceKey,
      "",
      "Keep this email: you can paste the key again after reinstalling or on another Mac.",
      "Lost it? Request it again from the \"Resend my key\" page and it will be sent to this address.",
    ].join("\n"),
  };
}

export function resendMailer(apiKey: string, from: string, doFetch: typeof fetch): Mailer {
  return {
    async sendLicence(to, licenceKey) {
      const { subject, text } = licenceEmail(licenceKey);
      const response = await doFetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from, to: [to], subject, text }),
      });
      if (!response.ok) throw new Error(`mail provider answered ${response.status}`);
    },
  };
}
