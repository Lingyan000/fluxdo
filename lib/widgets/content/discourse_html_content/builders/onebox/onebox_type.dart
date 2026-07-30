// Onebox 类型枚举和识别函数

/// Onebox 类型枚举
enum OneboxType {
  // GitHub 系列
  githubRepo,
  githubBlob,
  githubIssue,
  githubPullRequest,
  githubCommit,
  githubGist,
  githubFolder,
  githubActions,

  // 社交媒体
  twitterStatus,
  reddit,
  instagram,
  threads,
  tiktok,

  // 视频
  youtube,
  vimeo,
  loom,

  // 技术
  stackExchange,
  hackernews,
  pastebin,

  // 文档
  googleDocs,
  pdf,

  // 购物
  amazon,

  // 音频
  spotify,

  // Discourse
  discourseTopic,

  // 用户
  userOnebox,

  // 默认
  defaultOnebox,
}

/// 检测 onebox 类型
OneboxType detectOneboxType(dynamic element) {
  // 获取所有 class
  final Set<String> classes = {};

  // 收集 element 自身的 class
  if (element.classes != null) {
    classes.addAll(element.classes.cast<String>());
  }

  // 收集 aside 元素的 class
  final aside = element.querySelector('aside');
  if (aside != null && aside.classes != null) {
    classes.addAll(aside.classes.cast<String>());
  }

  // 收集 article 元素的 class
  final article = element.querySelector('article');
  if (article != null && article.classes != null) {
    classes.addAll(article.classes.cast<String>());
  }

  // 用户 onebox (优先检查)
  if (classes.contains('user-onebox')) {
    return OneboxType.userOnebox;
  }

  // GitHub 系列
  if (classes.contains('github-onebox') || classes.contains('onebox-github')) {
    // 更细分的 GitHub 类型 - 只依赖明确的 class 名
    if (classes.contains('githubblob')) {
      return OneboxType.githubBlob;
    }
    if (classes.contains('githubissue')) {
      return OneboxType.githubIssue;
    }
    if (classes.contains('githubpullrequest')) {
      return OneboxType.githubPullRequest;
    }
    if (classes.contains('githubcommit')) {
      return OneboxType.githubCommit;
    }
    if (classes.contains('githubgist')) {
      return OneboxType.githubGist;
    }
    if (classes.contains('githubfolder')) {
      return OneboxType.githubFolder;
    }
    if (classes.contains('githubactions')) {
      return OneboxType.githubActions;
    }
    // 尝试从 URL 检测具体类型
    final url = _extractUrlFromElement(element);
    if (url.isNotEmpty) {
      return _detectGithubTypeFromUrl(url);
    }
    // 默认为 GitHub Repo
    return OneboxType.githubRepo;
  }

  // 直接匹配 GitHub 类型 class
  if (classes.contains('githubrepo')) return OneboxType.githubRepo;
  if (classes.contains('githubblob')) return OneboxType.githubBlob;
  if (classes.contains('githubissue')) return OneboxType.githubIssue;
  if (classes.contains('githubpullrequest'))
    return OneboxType.githubPullRequest;
  if (classes.contains('githubcommit')) return OneboxType.githubCommit;
  if (classes.contains('githubgist')) return OneboxType.githubGist;
  if (classes.contains('githubfolder')) return OneboxType.githubFolder;
  if (classes.contains('githubactions')) return OneboxType.githubActions;

  // 社交媒体
  if (classes.contains('twitterstatus') || classes.contains('twitter-tweet')) {
    return OneboxType.twitterStatus;
  }
  if (classes.contains('reddit') || classes.contains('reddit-onebox')) {
    return OneboxType.reddit;
  }
  if (classes.contains('instagram-onebox') || classes.contains('instagram')) {
    return OneboxType.instagram;
  }
  if (classes.contains('threads-onebox')) {
    return OneboxType.threads;
  }
  if (classes.contains('tiktok-onebox')) {
    return OneboxType.tiktok;
  }

  // 视频
  if (classes.contains('youtube-onebox') || classes.contains('lazyYT')) {
    return OneboxType.youtube;
  }
  if (classes.contains('vimeo-onebox')) {
    return OneboxType.vimeo;
  }
  if (classes.contains('loom-onebox')) {
    return OneboxType.loom;
  }

  // 技术
  if (classes.contains('stackexchange-onebox') ||
      classes.contains('stackoverflow-onebox')) {
    return OneboxType.stackExchange;
  }
  if (classes.contains('hackernews-onebox') ||
      classes.contains('ycombinator')) {
    return OneboxType.hackernews;
  }
  if (classes.contains('pastebin-onebox')) {
    return OneboxType.pastebin;
  }

  // 文档
  if (classes.contains('googledocs-onebox')) {
    return OneboxType.googleDocs;
  }
  if (classes.contains('pdf-onebox')) {
    return OneboxType.pdf;
  }

  // 购物
  if (classes.contains('amazon-onebox')) {
    return OneboxType.amazon;
  }

  // 音频
  if (classes.contains('spotify-onebox')) {
    return OneboxType.spotify;
  }

  // Discourse 话题
  if (classes.contains('discoursetopic-onebox')) {
    return OneboxType.discourseTopic;
  }

  // 通过 data-onebox-src 或 URL 检测
  final dataSource = element.attributes['data-onebox-src'] ?? '';
  final headerLink =
      element.querySelector('header a')?.attributes['href'] ?? '';
  final url = dataSource.isNotEmpty ? dataSource : headerLink;

  if (url.contains('github.com')) {
    return _detectGithubTypeFromUrl(url);
  }
  if (url.contains('twitter.com') || url.contains('x.com')) {
    return OneboxType.twitterStatus;
  }
  if (url.contains('youtube.com') || url.contains('youtu.be')) {
    return OneboxType.youtube;
  }
  if (url.contains('reddit.com')) {
    return OneboxType.reddit;
  }
  if (url.contains('stackoverflow.com') || url.contains('stackexchange.com')) {
    return OneboxType.stackExchange;
  }
  if (url.contains('news.ycombinator.com')) {
    return OneboxType.hackernews;
  }
  if (url.contains('open.spotify.com') || url.contains('spotify.com')) {
    return OneboxType.spotify;
  }

  return OneboxType.defaultOnebox;
}

/// 从 URL 检测 GitHub 类型
OneboxType _detectGithubTypeFromUrl(String url) {
  if (url.contains('/blob/') || url.contains('/tree/')) {
    return url.contains('/blob/')
        ? OneboxType.githubBlob
        : OneboxType.githubFolder;
  }
  if (url.contains('/issues/') || url.contains('/issue/')) {
    return OneboxType.githubIssue;
  }
  if (url.contains('/pull/') || url.contains('/pulls/')) {
    return OneboxType.githubPullRequest;
  }
  if (url.contains('/commit/') || url.contains('/commits/')) {
    return OneboxType.githubCommit;
  }
  if (url.contains('gist.github.com')) {
    return OneboxType.githubGist;
  }
  if (url.contains('/actions/')) {
    return OneboxType.githubActions;
  }
  return OneboxType.githubRepo;
}

/// 从元素提取 URL
String _extractUrlFromElement(dynamic element) {
  // 尝试从 data-onebox-src 获取
  final dataSource = element.attributes['data-onebox-src'];
  if (dataSource != null && dataSource.isNotEmpty) {
    return dataSource;
  }

  // 尝试从 header 链接获取
  final headerLink = element.querySelector('header a');
  if (headerLink != null) {
    return headerLink.attributes['href'] ?? '';
  }

  // 尝试从 h3 链接获取
  final h3Link = element.querySelector('h3 a');
  if (h3Link != null) {
    return h3Link.attributes['href'] ?? '';
  }

  return '';
}

/// 获取类型的显示名称
String getOneboxTypeName(OneboxType type) {
  switch (type) {
    case OneboxType.githubRepo:
      return 'GitHub Repository';
    case OneboxType.githubBlob:
      return 'GitHub File';
    case OneboxType.githubIssue:
      return 'GitHub Issue';
    case OneboxType.githubPullRequest:
      return 'GitHub Pull Request';
    case OneboxType.githubCommit:
      return 'GitHub Commit';
    case OneboxType.githubGist:
      return 'GitHub Gist';
    case OneboxType.githubFolder:
      return 'GitHub Folder';
    case OneboxType.githubActions:
      return 'GitHub Actions';
    case OneboxType.twitterStatus:
      return 'Twitter';
    case OneboxType.reddit:
      return 'Reddit';
    case OneboxType.instagram:
      return 'Instagram';
    case OneboxType.threads:
      return 'Threads';
    case OneboxType.tiktok:
      return 'TikTok';
    case OneboxType.youtube:
      return 'YouTube';
    case OneboxType.vimeo:
      return 'Vimeo';
    case OneboxType.loom:
      return 'Loom';
    case OneboxType.stackExchange:
      return 'Stack Exchange';
    case OneboxType.hackernews:
      return 'Hacker News';
    case OneboxType.pastebin:
      return 'Pastebin';
    case OneboxType.googleDocs:
      return 'Google Docs';
    case OneboxType.pdf:
      return 'PDF';
    case OneboxType.amazon:
      return 'Amazon';
    case OneboxType.spotify:
      return 'Spotify';
    case OneboxType.discourseTopic:
      return 'Discourse Topic';
    case OneboxType.userOnebox:
      return 'User';
    case OneboxType.defaultOnebox:
      return 'Link';
  }
}
