// Jenkins initialization script — runs once at startup
// Reads credentials from environment variables injected at container run time.
// Fallback values are intentionally insecure and must NOT be used in production.
import jenkins.model.*
import hudson.security.*
import hudson.security.csrf.DefaultCrumbIssuer

def instance = Jenkins.getInstance()

// ------------------------------------------------------------------
// 1. Admin account
// ------------------------------------------------------------------
def adminUser = System.getenv("JENKINS_ADMIN_USER") ?: "admin"
def adminPass = System.getenv("JENKINS_ADMIN_PASSWORD") ?: "ChangeMe123!"

def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount(adminUser, adminPass)
instance.setSecurityRealm(hudsonRealm)

// ------------------------------------------------------------------
// 2. Authorization: full control when logged in, no anonymous access
// ------------------------------------------------------------------
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// ------------------------------------------------------------------
// 3. Enable CSRF protection (crumb issuer)
//    proxyCompatibility=true allows API calls through a reverse proxy
// ------------------------------------------------------------------
instance.setCrumbIssuer(new DefaultCrumbIssuer(true))

instance.save()
println("Jenkins security initialized — admin user: ${adminUser}")
