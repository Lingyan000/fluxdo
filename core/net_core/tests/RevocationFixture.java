import java.security.*;
import java.security.cert.*;

// 提供者能力由 SPI 决定；默认实现与 Android 系统提供者一样抛出“不支持”。
public class RevocationFixture {
    public static CertPathValidator validator(int mode) {
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
