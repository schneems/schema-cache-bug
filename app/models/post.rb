class Post < ApplicationRecord
  belongs_to :user

  def self.open_posts
    where("")
  end
end
