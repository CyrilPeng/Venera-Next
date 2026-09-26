// Documentation template only. example.invalid is not a real comic service.
// Replace the endpoints and mappings with an API you are authorized to use.
class ExampleSource extends ComicSource {
    name = "Example Source";
    key = "example_source";
    version = "1.0.0";
    minAppVersion = "1.16.0";
    url = "https://example.invalid/sources/example.js";
    api = "https://example.invalid/api";

    async requestJson(path) {
        const response = await Network.get(this.api + path, {
            "Accept": "application/json"
        });
        if (response.status !== 200) {
            throw new Error("Example API returned HTTP " + response.status);
        }
        return JSON.parse(response.body);
    }

    search = {
        optionList: [],
        load: async (keyword, options, page) => {
            const data = await this.requestJson(
                "/search?q=" + encodeURIComponent(keyword) + "&page=" + page
            );
            return {
                comics: data.items.map(item => new Comic({
                    id: String(item.id),
                    title: item.title,
                    subtitle: item.author,
                    cover: item.cover,
                    tags: item.tags || []
                })),
                maxPage: data.totalPages
            };
        }
    };

    comic = {
        loadInfo: async id => {
            const data = await this.requestJson("/comics/" + encodeURIComponent(id));
            const chapters = {};
            for (const chapter of data.chapters) {
                // Use stable non-integer keys to preserve the service's order.
                chapters["ep_" + chapter.id] = chapter.title;
            }
            return new ComicDetails({
                title: data.title,
                subtitle: data.author,
                cover: data.cover,
                description: data.description,
                tags: { author: [data.author] },
                chapters: chapters,
                updateTime: data.updatedOn,
                url: "https://example.invalid/comics/" + encodeURIComponent(id)
            });
        },

        loadEp: async (comicId, epId) => {
            if (typeof epId !== "string" || !epId.startsWith("ep_")) {
                throw new Error("Unknown chapter");
            }
            const data = await this.requestJson(
                "/comics/" + encodeURIComponent(comicId) +
                "/chapters/" + encodeURIComponent(epId.slice(3))
            );
            return { images: data.images };
        },

        onImageLoad: (imageKey, comicId, epId) => ({
            url: imageKey,
            headers: { "Referer": "https://example.invalid/" }
        }),

        // This callback must be synchronous.
        onThumbnailLoad: imageKey => ({
            url: imageKey,
            headers: { "Referer": "https://example.invalid/" }
        }),

        onClickTag: (namespace, tag) => ({
            page: "search",
            attributes: { text: tag }
        })
    };
}
