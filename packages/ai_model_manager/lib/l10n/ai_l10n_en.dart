import 'ai_l10n.dart';

/// 英文翻译
class AiL10nEn extends AiL10n {
  // ---- 通用 ----
  @override
  String get cancel => 'Cancel';
  @override
  String get delete => 'Delete';
  @override
  String get save => 'Save';
  @override
  String get add => 'Add';
  @override
  String get edit => 'Edit';
  @override
  String get manage => 'Manage';
  @override
  String get remove => 'Remove';
  @override
  String get test => 'Test';
  @override
  String get notSet => 'Not set';
  @override
  String get name => 'Name';
  @override
  String get import_ => 'Import';

  // ---- Quick prompts ----
  @override
  String get quickPromptsManageTitle => 'Quick prompts';
  @override
  String get quickPromptsImageTab => 'Image';
  @override
  String get quickPromptsTextTab => 'Text';
  @override
  String get quickPromptsBuiltInSection => 'Built-in';
  @override
  String get quickPromptsCustomSection => 'Custom';
  @override
  String get quickPromptsAddNew => 'New quick prompt';
  @override
  String get quickPromptsEditTitle => 'Edit quick prompt';
  @override
  String get quickPromptsCreateTitle => 'New quick prompt';
  @override
  String get quickPromptsName => 'Name';
  @override
  String get quickPromptsNameHint => 'e.g. Hand-drawn infographic';
  @override
  String get quickPromptsType => 'Type';
  @override
  String get quickPromptsIcon => 'Icon';
  @override
  String get quickPromptsIconTab => 'Icon';
  @override
  String get quickPromptsEmojiTab => 'Emoji';
  @override
  String get quickPromptsEmojiInputHint => 'Type or paste an emoji';
  @override
  String get quickPromptsTemplate => 'Prompt template';
  @override
  String get quickPromptsTemplateHint => 'Supports {title} {context}';
  @override
  String get quickPromptsAspect => 'Default aspect';
  @override
  String get quickPromptsTags => 'Tags';
  @override
  String get quickPromptsTagsHint => 'Comma-separated';
  @override
  String get quickPromptsDimensions => 'Dimensions (advanced)';
  @override
  String get quickPromptsTestGenerate => 'Test generate';
  @override
  String get quickPromptsTesting => 'Testing…';
  @override
  String get quickPromptsTestSuccess => 'Test image generated';
  @override
  String get quickPromptsTestFailed => 'Test failed';
  @override
  String get quickPromptsResetBuiltIns => 'Reset built-ins';
  @override
  String get quickPromptsResetBuiltInsConfirm =>
      'Reset all built-in quick prompts to default? (Custom prompts unaffected)';
  @override
  String get quickPromptsHide => 'Hide';
  @override
  String get quickPromptsUnhide => 'Show';
  @override
  String get quickPromptsDuplicate => 'Duplicate';
  @override
  String quickPromptsDeleteConfirm(String name) =>
      'Delete quick prompt "$name"?';
  @override
  String get quickPromptsPin => 'Pin to chat';
  @override
  String get quickPromptsUnpin => 'Unpin';
  @override
  String get quickPromptsValidateNameRequired => 'Please enter a name';
  @override
  String get quickPromptsValidateTemplateRequired =>
      'Please enter a prompt template';
  @override
  String get quickPromptsEmpty => 'No custom quick prompts yet';
  @override
  String get quickPromptsAspectAuto => 'Auto';
  @override
  String get quickPromptsTypeImage => 'Image';
  @override
  String get quickPromptsTypeText => 'Text';
  @override
  String get quickPromptsManageHint =>
      'Manage the quick prompts at the bottom of the AI assistant';

  // ---- AI 模型服务页 ----
  @override
  String get aiModelService => 'AI Model Service';
  @override
  String get providersTitle => 'Providers';
  @override
  String get addProvider => 'Add Provider';
  @override
  String get editProvider => 'Edit Provider';
  @override
  String get noProviderConfigured => 'No AI provider configured';
  @override
  String get addProviderHint =>
      'Add a provider to use the AI assistant feature';
  @override
  String get confirmDelete => 'Confirm Delete';
  @override
  String confirmDeleteProvider(String name) =>
      'Are you sure you want to delete provider "$name"?';
  @override
  String get pinProvider => 'Pin';
  @override
  String get unpinProvider => 'Unpin';
  @override
  String get pinnedProvidersSection => 'Pinned Providers';
  @override
  String get otherProvidersSection => 'Other Providers';
  @override
  String selectedProviderCount(int count) => '$count selected';
  @override
  String get deleteSelectedProviders => 'Delete Selected';
  @override
  String confirmDeleteSelectedProviders(int count) =>
      'Delete the selected $count providers?';
  @override
  String modelCount(int enabled, int total) => '$enabled/$total models';
  @override
  @override
  String get modelConfig => 'Model Config';
  @override
  String get defaultChatModel => 'Default Chat Model';
  @override
  String get defaultImageModel => 'Default Image Model';
  @override
  String get advancedSettings => 'Advanced';
  @override
  String get presetExport => 'Export';
  @override
  String get presetExportAll => 'Export all custom';
  @override
  String get presetImport => 'Import from clipboard';
  @override
  String get presetExportSuccess => 'Copied to clipboard';
  @override
  String presetImportCount(int count) => 'Imported $count presets';
  @override
  String get presetImportEmpty => 'No valid preset data in clipboard';
  @override
  String get presetImportPreview => 'Presets to import';
  @override
  String get presetImportConfirm => 'Import';
  @override
  String get thinkingLevelLabel => 'Thinking Depth';
  @override
  String get thinkingOff => 'Off';
  @override
  String get thinkingAuto => 'Auto';
  @override
  String get thinkingCustom => 'Custom';
  @override
  String get thinkingLow => 'Light';
  @override
  String get thinkingMedium => 'Medium';
  @override
  String get thinkingHigh => 'Deep';
  @override
  String get chatHistory => 'Chat History';
  @override
  String get titleGenerationModel => 'Title Generation Model';
  @override
  String get autoGenerateTitleSubtitle =>
      'Auto-generate titles for new sessions';
  @override
  String get noAutoGenerateTitle => 'Do not auto-generate titles';
  @override
  String get maxSessionCount => 'Max Session Count';
  @override
  String get autoDeleteOldestSession =>
      'Auto-delete oldest session when limit is exceeded';
  @override
  String get sessionManagement => 'Session Management';
  @override
  String totalSessionCount(int count) => '$count sessions total';

  // ---- 网络设置 ----
  @override
  String get useAppNetwork => 'Follow App Network Config';
  @override
  String get useAppNetworkSubtitle =>
      'AI requests will use the app\'s proxy and network settings when enabled';

  // ---- 供应商编辑页 ----
  @override
  String get pleaseEnterBaseUrlAndApiKey =>
      'Please enter Base URL and API Key';
  @override
  String get connectionSuccess => 'Connection successful';
  @override
  String get connectionFailed => 'Connection failed';
  @override
  String connectionFailedWithError(String error) =>
      'Connection failed: $error';
  @override
  String fetchedModelsCount(int count) => 'Fetched $count models';
  @override
  String fetchModelsFailed(String error) => 'Failed to fetch models: $error';
  @override
  String get addModelManually => 'Add Model Manually';
  @override
  String get modelId => 'Model ID';
  @override
  String get modelIdHint => 'e.g. gpt-4o';
  @override
  String get pleaseEnterProviderName => 'Please enter provider name';
  @override
  String get pleaseEnterBaseUrl => 'Please enter Base URL';
  @override
  String get pleaseEnterApiKey => 'Please enter API Key';
  @override
  String get pleaseEnterBaseUrlAndApiKeyFirst =>
      'Please enter Base URL and API Key first';
  @override
  String saveFailed(String error) => 'Save failed: $error';
  @override
  String get defaultModelCleared => 'Default model cleared';
  @override
  String get setAsDefaultModel => 'Set as default model';
  @override
  String modelAvailable(String id) => 'Model $id is available';
  @override
  String modelUnavailable(String id, String error) =>
      'Model $id unavailable: $error';
  @override
  String get basicConfig => 'Basic Configuration';
  @override
  String get nameHint => 'e.g. My OpenAI';
  @override
  String get providerType => 'Provider Type';
  @override
  String get connectivityCheck => 'Connectivity Check';
  @override
  String get modelManagement => 'Model Management';
  @override
  String get fetchModels => 'Fetch Models';
  @override
  String get manuallyAdd => 'Add Manually';
  @override
  String get cancelDefault => 'Unset Default';
  @override
  String get setAsDefault => 'Set Default';
  @override
  String get setAsImageDefault => 'Set as image default';
  @override
  String get imageDefaultActive => 'Image default';
  @override
  String get setAsTextDefault => 'Set as text default';
  @override
  String get textDefaultActive => 'Text default';
  @override
  String get imageDefaultModelCleared => 'Image default cleared';
  @override
  String get textDefaultModelCleared => 'Text default cleared';
  @override
  String get setAsImageDefaultDone => 'Set as image default';
  @override
  String get setAsTextDefaultDone => 'Set as text default';

  // ---- 聊天历史页 ----
  @override
  String get sessionHistory => 'Session History';
  @override
  String get clearAllConversations => 'Clear all conversations';
  @override
  String get noSessionHistory => 'No session history';
  @override
  String confirmDeleteAllSessions(int count) =>
      'Are you sure you want to delete all $count sessions? This action cannot be undone.';
  @override
  String get clearAll => 'Clear All';
  @override
  String topicWithId(int id) => 'Topic #$id';
  @override
  String sessionCount(int count) => '$count sessions';
  @override
  String get deleteAllTopicSessions => 'Delete all sessions for this topic';
  @override
  String get unnamedSession => 'Unnamed session';
  @override
  String get deleteTopicSessions => 'Delete Topic Sessions';
  @override
  String confirmDeleteTopicSessions(String title) =>
      'Are you sure you want to delete all sessions for "$title"?';
  @override
  String get justNow => 'Just now';
  @override
  String minutesAgo(int count) => '$count min ago';
  @override
  String hoursAgo(int count) => '$count hr ago';
  @override
  String daysAgo(int count) => '$count days ago';

  // ---- 上下文选项 ----
  @override
  String get firstPostOnly => 'First post only';
  @override
  String get first5Posts => 'First 5 posts';
  @override
  String get first10Posts => 'First 10 posts';
  @override
  String get first20Posts => 'First 20 posts';
  @override
  String get allPosts => 'All posts';

  // ---- 网络错误 ----
  @override
  String get connectionTimeoutError =>
      'Connection timed out. Please check your network or Base URL';
  @override
  String get cannotConnectError =>
      'Cannot connect to server. Please check your Base URL';
  @override
  @override
  String get apiKeyNotFoundError =>
      'Unable to read API Key. Please reconfigure the provider';
  @override
  String get apiKeyInvalidError => 'API Key is invalid or expired (401)';
  @override
  String get noAccessPermissionError =>
      'No access permission. Please check your API Key (403)';
  @override
  String get endpointNotFoundError =>
      'Endpoint not found. Please check your Base URL (404)';
  @override
  String get tooManyRequestsError =>
      'Too many requests. Please try again later (429)';
  @override
  String serverInternalError(int code) => 'Server internal error ($code)';
  @override
  String get upstreamBadGatewayError =>
      'Upstream service error (502 Bad Gateway). If using a proxy (one-api / aihubmix etc.), check that the proxy is healthy.';
  @override
  String get upstreamUnavailableError =>
      'Upstream service unavailable (503). OpenAI is busy or the proxy is overloaded; auto-retried 3 times without success, please try again later.';
  @override
  String get upstreamGatewayTimeoutError =>
      'Upstream timeout (504 Gateway Timeout). Slow requests such as gpt-image often trigger this; try a shorter prompt, lower quality, or connect directly without a proxy.';
  @override
  String requestFailed(int code) => 'Request failed ($code)';
  @override
  String get requestCancelled => 'Request cancelled';
  @override
  String get sslCertificateError => 'SSL certificate verification failed';
  @override
  String get networkConnectionFailed =>
      'Network connection failed. Please check your network settings';
  @override
  String get unknownNetworkError => 'Unknown network error';
  @override
  String get emptyResponseError =>
      'No response received from AI. Please check network settings or retry';

  // ---- Image generation settings ----
  @override
  String get partialImagesTitle => 'Image generation: progressive frames';
  @override
  String get partialImagesSubtitle =>
      'When enabled, gpt-image models stream blurry drafts before the final image. '
      'Requires a verified OpenAI organization; unverified accounts will fail.';
  @override
  String get imagePromptOptimizerModel => 'Image prompt optimizer model';
  @override
  String get imagePromptOptimizerSubtitle =>
      'Before image generation, use a chat model to translate topic context into '
      'a visual prompt — substantially improves image quality. '
      'Suggested: gpt-4o-mini / claude-haiku and other lightweight models.';
  @override
  String get optimizerNotSet => 'No optimization (concat raw context)';

  // ---- Model capability chips ----
  @override
  String get capabilityVisionLabel => 'Vision';
  @override
  String get capabilityReasoningLabel => 'Reasoning';
  @override
  String get capabilityToolLabel => 'Tools';
  @override
  String get capabilityImageOutputLabel => 'Image';
  @override
  String get capabilityResetTooltip => 'Reset to auto';
  @override
  String get capabilityResetSnack => 'Reset to auto-detection';

  // ---- Model detail sheet ----
  @override
  String get modelDetailTitle => 'Edit Model';
  @override
  String get modelDetailAddTitle => 'Add Model';
  @override
  String get modelDetailIdLabel => 'Model ID';
  @override
  String get modelDetailIdHint => 'e.g. gpt-4o';
  @override
  String get modelDetailNameLabel => 'Display Name';
  @override
  String get modelDetailInputLabel => 'Input Modalities';
  @override
  String get modelDetailOutputLabel => 'Output Modalities';
  @override
  String get modelDetailAbilitiesLabel => 'Abilities';
  @override
  String get modelDetailTextMode => 'Text';
  @override
  String get modelDetailImageMode => 'Image';
  @override
  String get modelDetailToolAbility => 'Tools';
  @override
  String get modelDetailReasoningAbility => 'Reasoning';
  @override
  String get modelDetailConfirm => 'Confirm';
  @override
  String get modelDetailResetAuto => 'Reset to auto';
  @override
  String get modelDetailIdCopied => 'Model ID copied';
  @override
  String get modelDetailIdRequired => 'Please enter a model ID';

  // ---- Provider edit tabs ----
  @override
  String get configTab => 'Config';
  @override
  String get modelsTab => 'Models';
  @override
  String get fetchModelsSelect => 'Select models to add';
  @override
  String get fetchModelsSelectAll => 'Select all';
  @override
  String get fetchModelsDeselectAll => 'Deselect all';
  @override
  String addSelectedModels(int count) => 'Add $count selected models';
  @override
  String get modelAlreadyAdded => 'Added';
  @override
  String get searchModelsHint => 'Search models';
  @override
  String get testModel => 'Test model';
  @override
  String get selectModelToTest => 'Select a model to test';

  // ---- System Prompts ----
  @override
  String get systemPromptIntro =>
      'You are a helpful AI assistant helping the user understand and discuss a forum topic.';
  @override
  String systemPromptTopicTitle(String title) => 'Topic title: $title';
  @override
  String get systemPromptContextHint =>
      'The user may ask you questions about the topic content. Please answer based on the provided context.';
  @override
  String get systemPromptMarkdown => 'Please respond in Markdown format.';
  @override
  String contextContentPrefix(String text) =>
      'Here is the topic content:\n$text';
  @override
  String get contextReadyResponse =>
      'OK, I have read the topic content. What questions do you have?';
  @override
  String imageContextPromptTemplate(String context, String userPrompt) =>
      'Please generate an image based on the discussion topic context below, '
      'but do NOT include the literal text in the image.\n\n'
      'Topic context:\n---\n$context\n---\n\n'
      'Image request: $userPrompt';

  @override
  String get titleGenerationPrompt =>
      'Summarize the topic of this text in no more than 10 words. Output the title text directly without punctuation or quotes.';
}
