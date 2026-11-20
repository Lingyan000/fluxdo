import java.security.Provider;
import java.security.cert.CertPathValidator;

public class AndroidRevocationProbe {
    public static void main(String[] args) throws Exception {
        Provider provider = (Provider) Class.forName(
            "com.android.internal.org.bouncycastle.jce.provider.BouncyCastleProvider")
            .getDeclaredConstructor().newInstance();
        CertPathValidator validator = CertPathValidator.getInstance("PKIX", provider);
        System.out.println("provider=" + provider.getName());
        System.out.println("implementation=" + provider.getService("CertPathValidator", "PKIX").getClassName());
        try {
            System.out.println("checker=" + validator.getRevocationChecker().getClass().getName());
            throw new AssertionError("Expected Android's default provider to report unsupported");
        } catch (UnsupportedOperationException expected) {
            System.out.println("confirmed=" + expected.getClass().getName());
        }
    }
}
