import 'ai_l10n.dart';

/// 繁體中文（台灣）翻譯
class AiL10nZhTW extends AiL10n {
  // ---- 通用 ----
  @override
  String get cancel => '取消';
  @override
  String get delete => '刪除';
  @override
  String get save => '儲存';
  @override
  String get add => '新增';
  @override
  String get edit => '編輯';
  @override
  String get manage => '管理';
  @override
  String get remove => '移除';
  @override
  String get test => '測試';
  @override
  String get notSet => '未設定';
  @override
  String get name => '名稱';
  @override
  String get import_ => '匯入';

  // ---- 快捷詞管理 ----
  @override
  String get quickPromptsManageTitle => '快捷詞管理';
  @override
  String get quickPromptsImageTab => '圖像';
  @override
  String get quickPromptsTextTab => '文字';
  @override
  String get quickPromptsBuiltInSection => '內建';
  @override
  String get quickPromptsCustomSection => '自訂';
  @override
  String get quickPromptsAddNew => '新增快捷詞';
  @override
  String get quickPromptsEditTitle => '編輯快捷詞';
  @override
  String get quickPromptsCreateTitle => '新增快捷詞';
  @override
  String get quickPromptsName => '名稱';
  @override
  String get quickPromptsNameHint => '如：手繪小報';
  @override
  String get quickPromptsType => '類型';
  @override
  String get quickPromptsIcon => '圖示';
  @override
  String get quickPromptsIconTab => '圖示';
  @override
  String get quickPromptsEmojiTab => 'Emoji';
  @override
  String get quickPromptsEmojiInputHint => '輸入或貼上 emoji';
  @override
  String get quickPromptsTemplate => 'Prompt 範本';
  @override
  String get quickPromptsTemplateHint => '支援 {title} {context}';
  @override
  String get quickPromptsAspect => '預設比例';
  @override
  String get quickPromptsTags => '標籤';
  @override
  String get quickPromptsTagsHint => '用逗號分隔';
  @override
  String get quickPromptsDimensions => '維度組合（進階）';
  @override
  String get quickPromptsTestGenerate => '測試生成';
  @override
  String get quickPromptsTesting => '測試中…';
  @override
  String get quickPromptsTestSuccess => '測試圖已生成';
  @override
  String get quickPromptsTestFailed => '測試失敗';
  @override
  String get quickPromptsResetBuiltIns => '恢復內建預設';
  @override
  String get quickPromptsResetBuiltInsConfirm =>
      '確定要恢復所有內建快捷詞的預設配置嗎？（不影響自訂）';
  @override
  String get quickPromptsHide => '隱藏';
  @override
  String get quickPromptsUnhide => '顯示';
  @override
  String get quickPromptsDuplicate => '複製';
  @override
  String quickPromptsDeleteConfirm(String name) => '確定刪除快捷詞「$name」嗎？';
  @override
  String get quickPromptsPin => 'Pin 到聊天頁';
  @override
  String get quickPromptsUnpin => '取消 Pin';
  @override
  String get quickPromptsValidateNameRequired => '請輸入名稱';
  @override
  String get quickPromptsValidateTemplateRequired => '請輸入 prompt 範本';
  @override
  String get quickPromptsEmpty => '還沒有自訂快捷詞';
  @override
  String get quickPromptsAspectAuto => '自動';
  @override
  String get quickPromptsTypeImage => '圖像';
  @override
  String get quickPromptsTypeText => '文字';
  @override
  String get quickPromptsManageHint => '管理 AI 助手底部的快捷詞';

  // ---- AI 模型服務頁 ----
  @override
  String get aiModelService => 'AI 模型服務';
  @override
  String get providersTitle => '供應商';
  @override
  String get addProvider => '新增供應商';
  @override
  String get editProvider => '編輯供應商';
  @override
  String get noProviderConfigured => '還沒有設定 AI 供應商';
  @override
  String get addProviderHint => '新增供應商後可以使用 AI 助手功能';
  @override
  String get confirmDelete => '確認刪除';
  @override
  String confirmDeleteProvider(String name) => '確定要刪除供應商「$name」嗎？';
  @override
  String get pinProvider => '置頂';
  @override
  String get unpinProvider => '取消置頂';
  @override
  String get pinnedProvidersSection => '置頂供應商';
  @override
  String get otherProvidersSection => '一般供應商';
  @override
  String selectedProviderCount(int count) => '已選 $count 個供應商';
  @override
  String get deleteSelectedProviders => '刪除選取';
  @override
  String confirmDeleteSelectedProviders(int count) =>
      '確定要刪除選取的 $count 個供應商嗎？';
  @override
  String modelCount(int enabled, int total) => '$enabled/$total 個模型';
  @override
  @override
  String get modelConfig => '模型設定';
  @override
  String get defaultChatModel => '預設聊天模型';
  @override
  String get defaultImageModel => '預設圖像模型';
  @override
  String get advancedSettings => '進階設定';
  @override
  String get presetExport => '匯出';
  @override
  String get presetExportAll => '匯出全部自訂';
  @override
  String get presetImport => '從剪貼簿匯入';
  @override
  String get presetExportSuccess => '已複製到剪貼簿';
  @override
  String presetImportCount(int count) => '匯入了 $count 個快捷詞';
  @override
  String get presetImportEmpty => '剪貼簿中沒有有效的快捷詞資料';
  @override
  String get presetImportPreview => '即將匯入以下快捷詞';
  @override
  String get presetImportConfirm => '確認匯入';
  @override
  String get thinkingLevelLabel => '思考深度';
  @override
  String get thinkingOff => '關閉思考';
  @override
  String get thinkingAuto => '自動';
  @override
  String get thinkingCustom => '自訂';
  @override
  String get thinkingLow => '輕度思考';
  @override
  String get thinkingMedium => '中度思考';
  @override
  String get thinkingHigh => '深度思考';
  @override
  String get chatHistory => '聊天紀錄';
  @override
  String get titleGenerationModel => '標題產生模型';
  @override
  String get autoGenerateTitleSubtitle => '自動為新會話產生標題';
  @override
  String get noAutoGenerateTitle => '不自動產生標題';
  @override
  String get maxSessionCount => '最大會話紀錄數';
  @override
  String get autoDeleteOldestSession => '超出上限時自動刪除最舊的會話';
  @override
  String get sessionManagement => '會話紀錄管理';
  @override
  String totalSessionCount(int count) => '共 $count 條會話';

  // ---- 網路設定 ----
  @override
  String get useAppNetwork => '跟隨應用網路設定';
  @override
  String get useAppNetworkSubtitle => '開啟後 AI 請求將使用應用的代理等網路設定';

  // ---- 供應商編輯頁 ----
  @override
  String get pleaseEnterBaseUrlAndApiKey => '請填寫 Base URL 和 API Key';
  @override
  String get connectionSuccess => '連線成功';
  @override
  String get connectionFailed => '連線失敗';
  @override
  String connectionFailedWithError(String error) => '連線失敗: $error';
  @override
  String fetchedModelsCount(int count) => '取得 $count 個模型';
  @override
  String fetchModelsFailed(String error) => '取得模型失敗: $error';
  @override
  String get addModelManually => '手動新增模型';
  @override
  String get modelId => '模型 ID';
  @override
  String get modelIdHint => '例如: gpt-4o';
  @override
  String get pleaseEnterProviderName => '請輸入供應商名稱';
  @override
  String get pleaseEnterBaseUrl => '請輸入 Base URL';
  @override
  String get pleaseEnterApiKey => '請輸入 API Key';
  @override
  String get pleaseEnterBaseUrlAndApiKeyFirst => '請先填寫 Base URL 和 API Key';
  @override
  String saveFailed(String error) => '儲存失敗: $error';
  @override
  String get defaultModelCleared => '已取消預設模型';
  @override
  String get setAsDefaultModel => '已設為預設模型';
  @override
  String modelAvailable(String id) => '模型 $id 可用';
  @override
  String modelUnavailable(String id, String error) => '模型 $id 不可用: $error';
  @override
  String get basicConfig => '基礎設定';
  @override
  String get nameHint => '例如: 我的 OpenAI';
  @override
  String get providerType => '供應商類型';
  @override
  String get connectivityCheck => '連線檢查';
  @override
  String get modelManagement => '模型管理';
  @override
  String get fetchModels => '取得模型';
  @override
  String get manuallyAdd => '手動新增';
  @override
  String get cancelDefault => '取消預設';
  @override
  String get setAsImageDefault => '設為圖像預設';
  @override
  String get imageDefaultActive => '圖像預設';
  @override
  String get setAsTextDefault => '設為文字預設';
  @override
  String get textDefaultActive => '文字預設';
  @override
  String get imageDefaultModelCleared => '已取消圖像預設';
  @override
  String get textDefaultModelCleared => '已取消文字預設';
  @override
  String get setAsImageDefaultDone => '已設為圖像預設';
  @override
  String get setAsTextDefaultDone => '已設為文字預設';
  @override
  String get setAsDefault => '設為預設';

  // ---- 聊天歷史頁 ----
  @override
  String get sessionHistory => '會話紀錄';
  @override
  String get clearAllConversations => '清除所有對話';
  @override
  String get noSessionHistory => '暫無會話紀錄';
  @override
  String confirmDeleteAllSessions(int count) =>
      '確定要刪除全部 $count 條會話紀錄嗎？此操作不可恢復。';
  @override
  String get clearAll => '清除全部';
  @override
  String topicWithId(int id) => '話題 #$id';
  @override
  String sessionCount(int count) => '$count 條會話';
  @override
  String get deleteAllTopicSessions => '刪除此話題所有會話';
  @override
  String get unnamedSession => '未命名會話';
  @override
  String get deleteTopicSessions => '刪除話題會話';
  @override
  String confirmDeleteTopicSessions(String title) =>
      '確定要刪除「$title」的所有會話紀錄嗎？';
  @override
  String get justNow => '剛剛';
  @override
  String minutesAgo(int count) => '$count 分鐘前';
  @override
  String hoursAgo(int count) => '$count 小時前';
  @override
  String daysAgo(int count) => '$count 天前';

  // ---- 上下文選項 ----
  @override
  String get firstPostOnly => '僅主帖';
  @override
  String get first5Posts => '前 5 樓';
  @override
  String get first10Posts => '前 10 樓';
  @override
  String get first20Posts => '前 20 樓';
  @override
  String get allPosts => '全部帖子';

  // ---- 網路錯誤 ----
  @override
  String get connectionTimeoutError => '連線逾時，請檢查網路或 Base URL 是否正確';
  @override
  String get cannotConnectError => '無法連線到伺服器，請檢查 Base URL 是否正確';
  @override
  @override
  String get apiKeyNotFoundError => '無法讀取 API Key，請重新配置供應商';
  @override
  String get apiKeyInvalidError => 'API Key 無效或已過期 (401)';
  @override
  String get noAccessPermissionError => '沒有存取權限，請檢查 API Key (403)';
  @override
  String get endpointNotFoundError => '介面位址不存在，請檢查 Base URL (404)';
  @override
  String get tooManyRequestsError => '請求過於頻繁，請稍後重試 (429)';
  @override
  String serverInternalError(int code) => '伺服器內部錯誤 ($code)';
  @override
  String get upstreamBadGatewayError =>
      '上游服務異常 (502 Bad Gateway)。如使用代理（one-api / aihubmix 等），請檢查代理服務是否正常。';
  @override
  String get upstreamUnavailableError =>
      '上游服務暫時不可用 (503)。OpenAI 服務繁忙或代理過載，已自動重試 3 次仍失敗，請稍後再試。';
  @override
  String get upstreamGatewayTimeoutError =>
      '上游回應逾時 (504 Gateway Timeout)。gpt-image 等慢請求容易觸發；請嘗試更短 prompt、降低畫質，或直連官方 API 不走代理。';
  @override
  String requestFailed(int code) => '請求失敗 ($code)';
  @override
  String get requestCancelled => '請求已取消';
  @override
  String get sslCertificateError => 'SSL 憑證驗證失敗';
  @override
  String get networkConnectionFailed => '網路連線失敗，請檢查網路設定';
  @override
  String get unknownNetworkError => '未知網路錯誤';
  @override
  String get emptyResponseError => '未收到 AI 回覆，請檢查網路設定或重試';

  // ---- 圖像生成設定 ----
  @override
  String get partialImagesTitle => '圖像生成漸進幀';
  @override
  String get partialImagesSubtitle =>
      '開啟後 gpt-image 系列會先回傳模糊草圖再回傳終態圖；'
      '需要 OpenAI 已驗證 organization，未驗證帳號開啟會失敗';
  @override
  String get imagePromptOptimizerModel => '圖像 Prompt 優化模型';
  @override
  String get imagePromptOptimizerSubtitle =>
      '畫圖前用聊天模型把話題上下文翻譯成視覺化 prompt，顯著提升出圖質量；'
      '推薦用 gpt-4o-mini / haiku 等輕量模型';
  @override
  String get optimizerNotSet => '不優化（直接拼接上下文）';

  // ---- 模型能力 chip ----
  @override
  String get capabilityVisionLabel => '識圖';
  @override
  String get capabilityReasoningLabel => '推理';
  @override
  String get capabilityToolLabel => '工具';
  @override
  String get capabilityImageOutputLabel => '畫圖';
  @override
  String get capabilityResetTooltip => '重置為自動';
  @override
  String get capabilityResetSnack => '已重置為自動推斷';

  // ---- 模型詳情 sheet ----
  @override
  String get modelDetailTitle => '編輯模型';
  @override
  String get modelDetailAddTitle => '新增模型';
  @override
  String get modelDetailIdLabel => '模型 ID';
  @override
  String get modelDetailIdHint => '例如: gpt-4o';
  @override
  String get modelDetailNameLabel => '顯示名稱';
  @override
  String get modelDetailInputLabel => '輸入模態';
  @override
  String get modelDetailOutputLabel => '輸出模態';
  @override
  String get modelDetailAbilitiesLabel => '模型能力';
  @override
  String get modelDetailTextMode => '文字';
  @override
  String get modelDetailImageMode => '圖像';
  @override
  String get modelDetailToolAbility => '工具呼叫';
  @override
  String get modelDetailReasoningAbility => '推理';
  @override
  String get modelDetailConfirm => '確認';
  @override
  String get modelDetailResetAuto => '重置為自動推斷';
  @override
  String get modelDetailIdCopied => '模型 ID 已複製';
  @override
  String get modelDetailIdRequired => '請輸入模型 ID';

  // ---- 供應商編輯頁 Tab ----
  @override
  String get configTab => '設定';
  @override
  String get modelsTab => '模型';
  @override
  String get fetchModelsSelect => '選擇要新增的模型';
  @override
  String get fetchModelsSelectAll => '全選';
  @override
  String get fetchModelsDeselectAll => '取消全選';
  @override
  String addSelectedModels(int count) => '新增選取的 $count 個模型';
  @override
  String get modelAlreadyAdded => '已新增';
  @override
  String get searchModelsHint => '搜尋模型';
  @override
  String get testModel => '測試模型';
  @override
  String get selectModelToTest => '選擇要測試的模型';

  // ---- System Prompts ----
  @override
  String get systemPromptIntro =>
      '你是一個有幫助的 AI 助手，正在幫助使用者理解和討論一個論壇話題。';
  @override
  String systemPromptTopicTitle(String title) => '話題標題：$title';
  @override
  String get systemPromptContextHint =>
      '使用者可能會就話題內容向你提問，請基於提供的上下文回答。';
  @override
  String get systemPromptMarkdown => '請用 Markdown 格式回覆。';
  @override
  String contextContentPrefix(String text) => '以下是話題內容：\n$text';
  @override
  String get contextReadyResponse => '好的，我已經閱讀了話題內容。請問你有什麼問題？';
  @override
  String imageContextPromptTemplate(String context, String userPrompt) =>
      '請基於下面的話題上下文生成一張圖，但不要把上下文文字直接畫到圖中。\n\n'
      '話題上下文：\n---\n$context\n---\n\n'
      '畫圖需求：$userPrompt';

  @override
  String get titleGenerationPrompt =>
      '請用不超過15個字概括使用者這段話的主題，直接輸出標題文字，不要加標點符號和引號。';
}
