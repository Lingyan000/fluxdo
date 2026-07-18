import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/storage/secret_store.dart';
import '../services/storage/system_secret_store.dart';

final secretStoreProvider = Provider<SecretStore>(
  (ref) => SystemSecretStore.instance,
);
