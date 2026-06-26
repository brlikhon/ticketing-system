import re
from typing import Optional, List

# Patterns that must never appear in customer_reply or recommended_next_action
FORBIDDEN_CREDENTIAL_PATTERNS = [
    r'\b(share|provide|enter|send|give|tell us|type|submit).{0,40}(pin|otp|password|passcode|card number|secret)\b',
    r'\b(verify|confirm).{0,30}(pin|otp|password)\b',
    r'\bwhat is your (pin|otp|password)\b',
    # Any direct mention of "your PIN" / "your OTP" etc. as standalone phrases
    r'\byour (pin|otp|password|passcode|cvv)\b',
    r'\bcall (?:us|me).{0,40}(?:verify|share|give|provide).{0,40}(pin|otp|password)\b',
    r'\bverify your identity\b',
]

FORBIDDEN_REFUND_PATTERNS = [
    r'\bwe will (refund|reverse|return|credit|unblock|recover)\b',
    r'\byour (refund|reversal|money) (will be|has been|is being) (processed|issued|credited|returned)\b',
    r'\bwe (guarantee|promise|confirm).{0,40}(refund|reversal|return)\b',
    r'\byou (will|shall) receive.{0,30}(refund|money|amount|taka)\b',
    r'\baccount will be unblocked\b',
    r'\bimmediately refund\b',
    r'\brefund (?:your )?(?:full )?balance\b',
    r'\bwe will unblock\b',
    r'\bwill be credited (?:back|to you)\b',
    r'\bwill be refunded\b',
]

FORBIDDEN_THIRD_PARTY_PATTERNS = [
    r'\bcontact.{0,30}(01[3-9]\d{8}|[0-9]{11})\b',  # raw phone numbers
    r'\bvisit.{0,30}(bit\.ly|tinyurl|t\.co|goo\.gl)\b',  # short URLs
    # Raw Bangladesh-style phone numbers anywhere in the text (with optional spaces)
    # Matches: +8801712345678, 8801712345678, 01712345678, 01 712 345 678, etc.
    r'(?:\+?88|0)1[3-9](?:[\s-]?\d){8}',
    # Generic "send money back to <account/bank/number>"
    r'\bsend (?:the )?(?:money )?(?:back )?to (?:my|other|their) (?:account|bank|number|wallet)\b',
    r'\bwire to\b',
]

SAFE_REFUND_REPLACEMENT = "any eligible amount will be returned through official channels"


def check_safety_violations(customer_reply: str, recommended_next_action: str) -> List[str]:
    """Returns a list of violation descriptions found."""
    violations: List[str] = []
    reply_lower = (customer_reply or "").lower()
    action_lower = (recommended_next_action or "").lower()

    for pattern in FORBIDDEN_CREDENTIAL_PATTERNS:
        if re.search(pattern, reply_lower, re.IGNORECASE):
            violations.append(f"CREDENTIAL_REQUEST_IN_REPLY: matched '{pattern}'")
        if re.search(pattern, action_lower, re.IGNORECASE):
            violations.append(f"CREDENTIAL_REQUEST_IN_ACTION: matched '{pattern}'")

    for pattern in FORBIDDEN_REFUND_PATTERNS:
        if re.search(pattern, reply_lower, re.IGNORECASE):
            violations.append(f"UNAUTHORIZED_REFUND_PROMISE_IN_REPLY: matched '{pattern}'")
        if re.search(pattern, action_lower, re.IGNORECASE):
            violations.append(f"UNAUTHORIZED_REFUND_PROMISE_IN_ACTION: matched '{pattern}'")

    for pattern in FORBIDDEN_THIRD_PARTY_PATTERNS:
        if re.search(pattern, reply_lower, re.IGNORECASE):
            violations.append(f"THIRD_PARTY_CONTACT_IN_REPLY: matched '{pattern}'")
        if re.search(pattern, action_lower, re.IGNORECASE):
            violations.append(f"THIRD_PARTY_CONTACT_IN_ACTION: matched '{pattern}'")

    return violations


def sanitize_reply(reply: str) -> str:
    """
    Hard-replace any detected unauthorized refund language, credential requests,
    or third-party contacts in customer_reply with safe phrasing.
    This is a last-resort fallback (the system prompt should prevent these
    phrases from being generated in the first place).
    """
    if not reply:
        return reply

    unsafe_phrases = [
        # --- Refund / unblock promises ---
        (r'\bwe will refund you\b', 'any eligible amount will be returned through official channels'),
        (r'\bwe will reverse the transaction\b', 'our team will investigate this transaction'),
        (r'\byour refund will be processed\b', 'any eligible amount will be returned through official channels'),
        (r'\bwe will credit your account\b', 'our team will review your account'),
        (r'\bwe will unblock\b', 'our team will review the status of your account'),
        (r'\baccount will be unblocked\b', 'account will be reviewed by our team'),
        (r'\bwill be credited (?:back|to you)\b', 'will be returned through official channels'),
        (r'\bwill be refunded\b', 'will be reviewed for any eligible return through official channels'),
        (r'\bimmediately refund\b', 'process any eligible return through official channels'),
        (r'\brefund (?:your )?(?:full )?balance\b', 'any eligible amount will be returned through official channels'),
        # --- Credential requests (should never reach here, but defensive) ---
        (r'\b(share|provide|enter|send|give|tell us|type|submit)\s+(?:your\s+)?(?:pin|otp|password|passcode|cvv|card number)\b',
         'never share such details with anyone'),
        (r'\bwhat is your (?:pin|otp|password)\b',
         'we will never ask for such details'),
        (r'\bverify your identity\b', 'our team will verify your case securely'),
    ]
    sanitized = reply
    for pattern, replacement in unsafe_phrases:
        sanitized = re.sub(pattern, replacement, sanitized, flags=re.IGNORECASE)
    return sanitized