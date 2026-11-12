import '../utils/time_utils.dart';
import 'category.dart';
import 'topic.dart';
import 'user.dart';

enum GroupDirectoryOrder {
  name('name'),
  members('user_count');

  const GroupDirectoryOrder(this.apiValue);
  final String apiValue;
}

class GroupDirectoryResult {
  const GroupDirectoryResult({
    required this.groups,
    required this.total,
    this.typeFilters = const [],
    this.moreUrl,
  });

  final List<UserGroupDetail> groups;
  final int total;
  final List<String> typeFilters;
  final String? moreUrl;

  factory GroupDirectoryResult.fromJson(Map<String, dynamic> json) =>
      GroupDirectoryResult(
        groups: (json['groups'] as List)
            .map(
              (item) => UserGroupDetail.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
        total: (json['total_rows_groups'] as num).toInt(),
        typeFilters: (json['extras']?['type_filters'] as List? ?? [])
            .cast<String>(),
        moreUrl: json['load_more_groups'] as String?,
      );
}

enum GroupSection { members, activity, permissions }

enum GroupActivityFilter { posts, topics, mentions }

enum GroupMemberOrder {
  username('username_lower'),
  joined('added_at'),
  lastPosted('last_posted_at'),
  lastSeen('last_seen_at');

  const GroupMemberOrder(this.apiValue);
  final String apiValue;
}

class UserGroupDetail {
  const UserGroupDetail({
    required this.group,
    required this.displayName,
    required this.canSeeMembers,
    this.bio,
    this.isMember = false,
    this.isOwner = false,
    this.automatic = false,
    this.bioExcerpt,
    this.flairUrl,
    this.flairColor,
    this.flairBackground,
    this.publicAdmission = false,
    this.publicExit = false,
    this.allowMembershipRequests = false,
    this.requestTemplate = '',
    this.messageable = false,
  });

  final TopicGroup group;
  final String displayName;
  final String? bio;
  final bool canSeeMembers;
  final bool isMember;
  final bool isOwner;
  final bool automatic;
  final String? bioExcerpt;
  final String? flairUrl;
  final String? flairColor;
  final String? flairBackground;
  final bool publicAdmission;
  final bool publicExit;
  final bool allowMembershipRequests;
  final String requestTemplate;
  final bool messageable;

  factory UserGroupDetail.fromJson(Map<String, dynamic> json) {
    final group = TopicGroup.fromJson(json);
    final displayName = (json['display_name'] as String?)?.trim();
    return UserGroupDetail(
      group: group,
      displayName: displayName?.isNotEmpty == true
          ? displayName!
          : group.displayName,
      bio: json['bio_cooked'] as String?,
      canSeeMembers: json['can_see_members'] == true,
      isMember: json['is_group_user'] == true,
      isOwner: json['is_group_owner'] == true,
      automatic: json['automatic'] == true,
      bioExcerpt: json['bio_excerpt'] as String?,
      flairUrl: json['flair_url'] as String?,
      flairColor: json['flair_color'] as String?,
      flairBackground: json['flair_bg_color'] as String?,
      publicAdmission: json['public_admission'] == true,
      publicExit: json['public_exit'] == true,
      allowMembershipRequests: json['allow_membership_requests'] == true,
      requestTemplate: json['membership_request_template'] as String? ?? '',
      messageable: json['messageable'] == true,
    );
  }

  // 写入已确认的成员状态，后续刷新失败时也不会重复提供相反的操作。
  UserGroupDetail withMembership(bool value) => UserGroupDetail(
    group: group,
    displayName: displayName,
    bio: bio,
    canSeeMembers: canSeeMembers,
    isMember: value,
    isOwner: isOwner,
    automatic: automatic,
    bioExcerpt: bioExcerpt,
    flairUrl: flairUrl,
    flairColor: flairColor,
    flairBackground: flairBackground,
    publicAdmission: publicAdmission,
    publicExit: publicExit,
    allowMembershipRequests: allowMembershipRequests,
    requestTemplate: requestTemplate,
    messageable: messageable,
  );
}

class GroupMembersPage {
  const GroupMembersPage({
    required this.members,
    required this.ownerIds,
    required this.offset,
    required this.limit,
    this.joinedAt = const {},
  });

  final List<User> members;
  final Set<int> ownerIds;
  final Map<int, DateTime?> joinedAt;
  final int offset;
  final int limit;

  // Discourse 的 meta.total 是未过滤总数，搜索分页以实际返回数量判断。
  bool get hasMore => members.length >= limit;

  factory GroupMembersPage.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'] as Map<String, dynamic>;
    final members = (json['members'] as List).cast<Map<String, dynamic>>();
    return GroupMembersPage(
      members: members.map(User.fromJson).toList(),
      ownerIds: (json['owners'] as List? ?? [])
          .map((item) => (item['id'] as num).toInt())
          .toSet(),
      joinedAt: {
        for (final member in members)
          (member['id'] as num).toInt(): TimeUtils.parseUtcTime(
            member['added_at'] as String?,
          ),
      },
      offset: (meta['offset'] as num).toInt(),
      limit: (meta['limit'] as num).toInt(),
    );
  }
}

class GroupActivityPost {
  const GroupActivityPost({
    required this.id,
    required this.topicId,
    required this.postNumber,
    required this.title,
    required this.user,
    this.excerpt = '',
    this.createdAt,
    this.categoryId,
  });

  final int id;
  final int topicId;
  final int postNumber;
  final String title;
  final User user;
  final String excerpt;
  final DateTime? createdAt;
  final int? categoryId;

  factory GroupActivityPost.fromJson(Map<String, dynamic> json) =>
      GroupActivityPost(
        id: json['id'] as int,
        topicId: json['topic_id'] as int,
        postNumber: json['post_number'] as int,
        title: json['topic_title'] as String? ?? '',
        user: User.fromJson({
          'id': json['user_id'],
          'username': json['username'],
          'name': json['name'],
          'avatar_template': json['avatar_template'],
          ...?json['user'] as Map<String, dynamic>?,
        }),
        excerpt: json['excerpt'] as String? ?? '',
        createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
        categoryId: json['category_id'] as int?,
      );
}

class GroupPostsPage {
  const GroupPostsPage({required this.posts, this.categories = const []});

  final List<GroupActivityPost> posts;
  final List<Category> categories;
  bool get hasMore => posts.length >= 20;

  factory GroupPostsPage.fromJson(Map<String, dynamic> json) => GroupPostsPage(
    posts: (json['posts'] as List)
        .map((item) => GroupActivityPost.fromJson(item as Map<String, dynamic>))
        .toList(),
    categories: (json['categories'] as List? ?? [])
        .map((item) => Category.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class GroupCategoryPermission {
  const GroupCategoryPermission({required this.category, required this.type});

  final Category category;
  final int type;

  factory GroupCategoryPermission.fromJson(Map<String, dynamic> json) =>
      GroupCategoryPermission(
        category: Category.fromJson(json['category'] as Map<String, dynamic>),
        type: json['permission_type'] as int,
      );
}
