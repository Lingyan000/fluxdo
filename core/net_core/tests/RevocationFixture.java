import java.security.*;
import java.security.cert.*;

// 提供者能力由 SPI 决定；默认实现与 Android 系统提供者一样抛出“不支持”。
public class RevocationFixture {
    // 使用真实 PKIX 校验器复现缺失响应地址，注入 CRL 避免依赖公网。
    public static String validate(byte[] leafDer, byte[] issuerDer, PKIXRevocationChecker checker,
                                  byte[] response, byte[] crl, long now) throws Exception {
        X509Certificate leaf = certificate(leafDer);
        PKIXParameters params = new PKIXParameters(java.util.Set.of(new TrustAnchor(certificate(issuerDer), null)));
        params.setDate(new java.util.Date(now * 1000));
        params.setRevocationEnabled(false);
        if (response != null) checker.setOcspResponses(java.util.Map.of(leaf, response));
        params.setCertPathCheckers(java.util.List.of(checker));
        if (crl != null) {
            CRL parsed = CertificateFactory.getInstance("X.509").generateCRL(new java.io.ByteArrayInputStream(crl));
            params.addCertStore(CertStore.getInstance("Collection",
                new CollectionCertStoreParameters(java.util.List.of(parsed))));
        }
        CertPath path = CertificateFactory.getInstance("X.509").generateCertPath(java.util.List.of(leaf));
        try {
            CertPathValidator.getInstance("PKIX").validate(path, params);
            return "OK";
        } catch (CertPathValidatorException error) {
            return error.getReason() + ": " + error.getMessage();
        }
    }

    public static X509Certificate certificate(byte[] der) throws CertificateException {
        return (X509Certificate) CertificateFactory.getInstance("X.509")
            .generateCertificate(new java.io.ByteArrayInputStream(der));
    }

    public static CertPathValidator validator(int mode) {
        if (mode == 3) {
            try {
                Provider android = (Provider) Class.forName(
                    "com.android.internal.org.bouncycastle.jce.provider.BouncyCastleProvider")
                    .getConstructor().newInstance();
                return CertPathValidator.getInstance("PKIX", android);
            } catch (ReflectiveOperationException | NoSuchAlgorithmException error) {
                throw new AssertionError(error);
            }
        }
        CertPathValidatorSpi spi = new CertPathValidatorSpi() {
            public CertPathValidatorResult engineValidate(CertPath path, CertPathParameters params) {
                throw new AssertionError("此测试只调用能力接口");
            }
            public CertPathChecker engineGetRevocationChecker() {
                if (mode == 0) return super.engineGetRevocationChecker();
                if (mode == 1) throw new SecurityException("校验器初始化被拒绝");
                try {
                    return CertPathValidator.getInstance("PKIX").getRevocationChecker();
                } catch (NoSuchAlgorithmException error) {
                    throw new AssertionError(error);
                }
            }
        };
        return new CertPathValidator(spi, new Provider("fixture", "1", "test") {}, "PKIX") {};
    }
}
