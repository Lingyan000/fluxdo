(function() {
	// examples/forum-activity/src/main.ts
	async function load(ctx) {
		ctx.setData("loading", true);
		ctx.setData("error", "");
		try {
			const account = await ctx.api.user.get();
			if (!account) throw new Error("请先登录");
			const result = await ctx.api.forum.read({
				resource: "actions",
				username: account.username,
				actions: ["topics", "replies"]
			});
			ctx.setData("items", result.items.map((item) => ({
				title: item.title ?? "",
				topicId: item.topicId,
				postNumber: item.postNumber ?? 1
			})));
		} catch (error) {
			ctx.setData("error", error instanceof Error ? error.message : String(error));
		} finally {
			ctx.setData("loading", false);
		}
	}
	fluxdo.on("page.open", load);
	fluxdo.on("page.refresh", load);
	fluxdo.on("refresh", load);
	fluxdo.on("open", async (ctx, args) => {
		await ctx.api.forum.open({
			type: "topic",
			topicId: Number(args.topicId),
			postNumber: Number(args.postNumber)
		});
	});
})();
