package sweetiebot

import (
	"database/sql"
	"errors"

	_ "github.com/go-sql-driver/mysql" // Blank import is the correct way to import a sql driver
)

type WebDB struct {
	db                        *sql.DB
	status                    AtomicBool
	driver                    string
	conn                      string
	sqlBlockUser             *sql.Stmt
	sqlUnblockUser             *sql.Stmt
	sqlAddCharge             *sql.Stmt
  sqlRemoveCharge             *sql.Stmt
	sqlAddComment             *sql.Stmt
	sqlEditComment             *sql.Stmt
  sqlRemoveComment             *sql.Stmt
  sqlAddExpense             *sql.Stmt
  sqlAddFlag             *sql.Stmt
  sqlAddGoal             *sql.Stmt
  sqlEditGoal             *sql.Stmt
	sqlRemoveGoal             *sql.Stmt
  sqlAddMessage             *sql.Stmt
  sqlEditMessage             *sql.Stmt
  sqlSendMessage             *sql.Stmt
  sqlRemoveMessage             *sql.Stmt
  sqlReadNotifications             *sql.Stmt
  sqlAddOAuth             *sql.Stmt
  sqlUpdateOAuth             *sql.Stmt
  sqlRemoveOAuth             *sql.Stmt
  sqlAddPage             *sql.Stmt
  sqlEditPage             *sql.Stmt
  sqlPublishPage             *sql.Stmt
  sqlUnpublishPage             *sql.Stmt
  sqlRemovePage             *sql.Stmt
  sqlSuspendPage             *sql.Stmt
  sqlReinstatePage             *sql.Stmt
  sqlProcessPayment             *sql.Stmt
  sqlProcessPayout             *sql.Stmt
  sqlAddPledge             *sql.Stmt
  sqlEditPledge             *sql.Stmt
  sqlRemovePledge             *sql.Stmt
  sqlAddPost             *sql.Stmt
  sqlEditPost             *sql.Stmt
  sqlPublishPost             *sql.Stmt
  sqlTakedownPost             *sql.Stmt
  sqlRemovePost             *sql.Stmt
  sqlAddReward             *sql.Stmt
  sqlEditReward             *sql.Stmt
  sqlRemoveReward             *sql.Stmt
  sqlAddSourceStripe             *sql.Stmt
  sqlEditSource             *sql.Stmt
  sqlRemoveSource             *sql.Stmt
  sqlAddUser             *sql.Stmt
  sqlEditUser             *sql.Stmt
  sqlBanUser             *sql.Stmt
  sqlRemoveUser             *sql.Stmt
}

func dbLoad(log logger, driver string, conn string) (*WebDB, error) {
	cdb, err := sql.Open(driver, conn)
	r := WebDB{}
	r.db = cdb
	r.status.set(err == nil)
	r.lastattempt = time.Now().UTC()
	r.log = log
	r.driver = driver
	r.conn = conn
	if err != nil {
		return &r, err
	}

	r.db.SetMaxOpenConns(70)
	err = r.db.Ping()
	r.status.set(err == nil)
	return &r, err
}


// Close destroys the database connection
func (db *BotDB) Close() {
	if db.db != nil {
		db.db.Close()
		db.db = nil
	}
}

// Prepare a sql statement and logs an error if it fails
func (db *BotDB) Prepare(s string) (*sql.Stmt, error) {
	statement, err := db.db.Prepare(s)
	if err != nil {
		fmt.Println("Preparing: ", s, "\nSQL Error: ", err.Error())
	}
	return statement, err
}

function (db *BotDB) LoadStatements() error {
	var err error
  
	db.sqlBlockUser, err = db.Prepare("INSERT INTO blocked (User, Blocked) VALUES (?,?)")
	db.sqlUnblockUser, err = db.Prepare("DELETE FROM blocked WHERE User = ? AND Blocked = ?")
	db.sqlAddCharge, err = db.Prepare("CALL AddCharge(?)")
  db.sqlRemoveCharge, err = db.Prepare("CALL RemoveCharge(?)")
	db.sqlAddComment, err = db.Prepare("CALL AddComment(?, ?, ?, ?)")
	db.sqlEditComment, err = db.Prepare("UPDATE comments SET Content = ?, Edited = CURRENT_TIMESTAMP() WHERE ID = ?")
  db.sqlRemoveComment, err = db.Prepare("UPDATE comments SET Content = '', Edited = CURRENT_TIMESTAMP() WHERE ID = ?")
  db.sqlAddExpense, err = db.Prepare("INSERT INTO expenses (Amount, Priority, Category) VALUES (?, ?, ?)")
  db.sqlAddFlag, err = db.Prepare("INSERT INTO flags (User, Data, Type) VALUES (?, ?, ?)")
  db.sqlAddGoal, err = db.Prepare("INSERT INTO goals (Page, Amount, Name, Description) VALUES (?, ?, ?)")
  db.sqlEditGoal, err = db.Prepare("UPDATE goals SET Amount = ?, Name = ?, Description = ? WHERE Page = ? AND Amount = ?")
	db.sqlRemoveGoal, err = db.Prepare("DELETE FROM goals WHERE Page = ? AND Amount = ?")
  db.sqlAddMessage, err = db.Prepare("INSERT INTO messages (Sender, Recipient, Title, Content) VALUES (?, ?, ?, ?)")
  db.sqlEditMessage, err = db.Prepare("CALL EditMessage(?, ?, ?, ?)")
  db.sqlSendMessage, err = db.Prepare("CALL SendMessage(?)")
  db.sqlRemoveMessage, err = db.Prepare("CALL RemoveMessage(?, ?)")
  db.sqlReadNotifications, err = db.Prepare("UPDATE users SET LastRead = CURRENT_TIMESTAMP() WHERE ID = ?")
  db.sqlAddOAuth, err = db.Prepare("INSERT INTO oauth (User, Service, AccessToken, RefreshToken, Expires, Scope) VALUES (?, ?, ?, ?, ?, ?)")
  db.sqlUpdateOAuth, err = db.Prepare("UPDATE oauth SET AccessToken = ?, RefreshToken = ?, Expires = ?, Scope = ? WHERE User = ? AND Service = ?")
  db.sqlRemoveOAuth, err = db.Prepare("DELETE FROM oauth WHERE User = ? AND Service = ?")
  db.sqlAddPage, err = db.Prepare("INSERT INTO pages (User, Name, Description, Item) VALUES (?, ?, ?, ?)")
  db.sqlEditPage, err = db.Prepare("UPDATE pages SET Monthly = ?, Restricted = ?, Sensitive = ?, Name = ?, Descriptoin = ?, Video = ?, Item = ?, Background = ?, Edited = CURRENT_TIMESTAMP() WHERE ID = ?")
  db.sqlPublishPage, err = db.Prepare("UPDATE pages SET Draft = 0 WHERE ID = ?")
  db.sqlUnpublishPage, err = db.Prepare("UPDATE pages SET Draft = 1 WHERE ID = ?")
  db.sqlRemovePage, err = db.Prepare("DELETE FROM pages WHERE ID = ?")
  db.sqlSuspendPage, err = db.Prepare("UPDATE pages SET Suspended = 1 WHERE ID = ?")
  db.sqlReinstatePage, err = db.Prepare("UPDATE pages SET Suspended = 0 WHERE ID = ?")
  db.sqlProcessPayment, err = db.Prepare("CALL ProcessPayment(?, ?, ?)")
  db.sqlProcessPayout, err = db.Prepare("CALL ProcessPayout(?, ?, ?)")
  db.sqlAddPledge, err = db.Prepare("CALL AddPledge(?, ?, ?, ?, ?, ?)") // This adds or edits a pledge
  db.sqlRemovePledge, err = db.Prepare("CALL RemovePledge(?, ?)")
  db.sqlAddPost, err = db.Prepare("INSERT INTO posts (Page, Title, Content) VALUES (Page, Title, Content)")
  db.sqlEditPost, err = db.Prepare("UPDATE posts SET Title = ?, Content = ?, Edited = CURRENT_TIMESTAMP(), Scheduled = ?, Charge = ?, Locked = ?, CreateCharge = ?, Sensitive = ? WHERE ID = ?")
  db.sqlPublishPost, err = db.Prepare("CALL PublishPost(?)")
  db.sqlTakedownPost, err = db.Prepare("UPDATE posts SET DMCA = 1 WHERE ID = ?")
  db.sqlRemovePost, err = db.Prepare("DELETE FROM posts WHERE ID = ?")
  db.sqlAddReward, err = db.Prepare("INSERT INTO rewards (Page, Order, Name, Description, Amount) VALUES (?, ?, ?, ?, ?)")
  db.sqlEditReward, err = db.Prepare("CALL EditReward(?, ?, ?, ?, ?)")
  db.sqlRemoveReward, err = db.Prepare("DELETE FROM rewards WHERE ID = ?")
  db.sqlAddSourceStripe, err = db.Prepare("CALL AddSourceStripe(?, ?)")
  //db.sqlEditSource
  db.sqlRemoveSource, err = db.Prepare("DELETE FROM sources WHERE ID = ?")
  db.sqlAddUser, err = db.Prepare("INSERT INTO users (Username, Password, Email, DisplayName) VALUES (?, ?, ?, ?)")
  db.sqlEditUser, err = db.Prepare("UPDATE users SET Username = ?, Password = ?, Email = ?, DisplayName = ?, About = ?, Privacy = ?, Edited = CURRENT_TIMESTAMP(), Currency = ?, Notify = ?, ShowSensitive = ? WHERE ID = ?")
  db.sqlEditUserPayout, err = db.Prepare("UPDATE users SET Foreign = ?, Individual = ?, StripeCustomerID = ? WHERE ID = ?")
  db.sqlBanUser, err = db.Prepare("UPDATE users SET Banned = 1 WHERE ID = ?")
  db.sqlRemoveUser, err = db.Prepare("DELETE FROM users WHERE ID = ?")
}